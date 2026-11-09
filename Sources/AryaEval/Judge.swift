import AryaAdapters
import AryaCore
import AryaRuntime

/// What a judge scores: one sample's result against the case's expected result.
public struct JudgeRequest: Hashable, Sendable, Codable {
    public var rehearsal: RehearsalID
    public var caseID: CaseID
    public var sample: Int
    public var input: String
    public var expected: JSONValue
    public var actual: JSONValue
    public var rubric: String

    enum CodingKeys: String, CodingKey {
        case rehearsal
        case caseID = "case"
        case sample, input, expected, actual, rubric
    }
}

/// A judge's score for one sample.
public struct JudgeVerdict: Hashable, Sendable, Codable {
    /// In `0...1`.
    public var value: Double
    public var passed: Bool
    public var notes: [String]

    public init(value: Double, passed: Bool, notes: [String] = []) {
        self.value = value
        self.passed = passed
        self.notes = notes
    }

    /// Reads an adapter's `run/result`, which is untrusted: `value` must be a finite number in
    /// `0...1`; `passed` defaults to `value >= passThreshold`; notes must be strings.
    public init(result: JSONValue?, passThreshold: Double) throws {
        let value: Double
        switch result?["value"] {
        case .double(let number)?: value = number
        case .int(let number)?: value = Double(number)
        default: throw EvalError.badVerdict("value must be a number in 0...1")
        }
        guard value.isFinite, (0...1).contains(value) else {
            throw EvalError.badVerdict("value must be a number in 0...1")
        }
        var passed = value >= passThreshold
        if let flag = result?["passed"] {
            guard case .bool(let given) = flag else {
                throw EvalError.badVerdict("passed must be a boolean")
            }
            passed = given
        }
        var notes: [String] = []
        if case .array(let items)? = result?["notes"] {
            notes = try items.map {
                guard case .string(let note) = $0 else {
                    throw EvalError.badVerdict("notes must be strings")
                }
                return note
            }
        }
        self.init(value: value, passed: passed, notes: Self.clean(notes))
    }

    /// Notes are shown verbatim, so they are made safe for one line: whitespace collapsed,
    /// empty notes dropped, each cut to 120 characters, at most 6 kept.
    static func clean(_ notes: [String]) -> [String] {
        let lines = notes.map { note in
            note.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        }
        return lines.filter { !$0.isEmpty }.prefix(6).map { line in
            line.count > 120 ? String(line.prefix(119)) + "…" : line
        }
    }

    func score(judge: String) -> CaseScore {
        let text =
            notes.isEmpty
            ? "value \(ResultText.value(.double(value)))" : notes.joined(separator: "; ")
        return CaseScore(
            value: value, passed: passed, notes: notes,
            checks: [
                CheckResult(
                    label: "judge \(judge)", passed: passed, text: text,
                    phrase: notes.isEmpty ? nil : notes.joined(separator: ", "))
            ])
    }
}

/// One sample's judgment as recorded in `rehearsal.case.scored`.
public struct JudgeRecord: Hashable, Sendable, Codable {
    public var sample: Int
    public var judge: String
    public var rubric: String
    /// `nil` when the judge failed; `error` says why and the sample scored 0.
    public var verdict: JudgeVerdict?
    public var error: String?
}

/// Scores a sample by asking someone (usually an adapter) to judge it.
public protocol CaseJudge: Sendable {
    /// Names the judge in the recorded judgment, e.g. the adapter name.
    var name: String { get }
    func judge(_ request: JudgeRequest) async throws -> JudgeVerdict
}

/// Judges with any adapter: one adapter session per sample whose instructions are the rubric
/// prompt, whose input is the case, expected and actual result as canonical JSON, and whose
/// `run/result` must be a verdict (`resultSchema` says so). Never executes anything: the
/// session gets no tools.
public struct AdapterJudge: CaseJudge {
    public var adapters: any AdapterFactory
    /// Selects the adapter (`adapter`), effort and limits.
    public var charter: Charter
    public var passThreshold: Double
    public var ambient: Ambient

    public init(
        adapters: any AdapterFactory, charter: Charter, passThreshold: Double = 1,
        ambient: Ambient
    ) {
        self.adapters = adapters
        self.charter = charter
        self.passThreshold = passThreshold
        self.ambient = ambient
    }

    public var name: String { charter.adapter }

    public static let verdictSchema: JSONValue = [
        "type": "object", "required": ["value"],
        "properties": [
            "value": ["type": "number", "minimum": 0, "maximum": 1],
            "passed": ["type": "boolean"],
            "notes": ["type": "array", "items": ["type": "string"]],
        ],
    ]

    public static func instructions(rubric: String) -> String {
        """
        You are judging a steward's result for one case. Compare `actual` with `expected` \
        using this rubric, then reply with a result {value: 0...1, passed, notes}.

        Rubric:
        \(rubric)
        """
    }

    public func judge(_ request: JudgeRequest) async throws -> JudgeVerdict {
        let run = ambient.newID(RunID.self)
        let adapter = try await adapters.makeAdapter(for: charter, run: run)
        var updates = adapter.updates.makeAsyncIterator()
        defer { Task { try? await adapter.shutdown() } }
        _ = try await adapter.initialize(
            InitializeParams(client: PeerInfo(name: "arya-judge", version: "0.1.0")))
        let input: JSONValue = [
            "case": .string(request.caseID.rawValue), "input": .string(request.input),
            "expected": request.expected, "actual": request.actual,
        ]
        let limits = charter.limits
        _ = try await adapter.start(
            RunStartParams(
                run: run.rawValue, instructions: Self.instructions(rubric: request.rubric),
                input: RunInput(kind: .manual, text: try CanonicalJSON.string(input)),
                effort: charter.effort.rawValue, workdir: "judge/\(run.rawValue)", tools: [],
                limits: RunLimits(
                    maxTurns: limits.maxTurns, timeoutSeconds: limits.timeoutSeconds,
                    maxCostMicros: limits.maxCostMicros),
                resultSchema: Self.verdictSchema))
        while let update = await updates.next() {
            switch update {
            case .result(let params):
                guard params.status == .completed else {
                    throw EvalError.badVerdict("judge run ended \(params.status)")
                }
                return try JudgeVerdict(result: params.result, passThreshold: passThreshold)
            case .exited, .timedOut:
                throw EvalError.badVerdict("judge ended without a result")
            case .ask(let id, _):
                try? await adapter.answer(id, HostAskResult(answer: nil))
            case .wire, .event, .protocolError:
                continue
            }
        }
        throw EvalError.badVerdict("judge ended without a result")
    }
}

/// Serves the judgments a rehearsal recorded, so replaying or re-scoring it never asks a judge
/// again. A sample without a recorded verdict throws.
public struct RecordedJudge: CaseJudge {
    public var name: String
    private let verdicts: [String: JudgeVerdict]

    public init(name: String = "recorded", events: [RuntimeEvent]) throws {
        self.name = name
        var verdicts: [String: JudgeVerdict] = [:]
        for event in events where event.type == EvalEventType.rehearsalCaseScored {
            let payload = try EvalPayload.decode(RehearsalCaseScoredPayload.self, event.payload)
            for record in payload.judgments ?? [] {
                let key = Self.key(payload.rehearsal, payload.caseID, record.sample)
                verdicts[key] = record.verdict
            }
        }
        self.verdicts = verdicts
    }

    public func judge(_ request: JudgeRequest) async throws -> JudgeVerdict {
        guard let verdict = verdicts[Self.key(request.rehearsal, request.caseID, request.sample)]
        else { throw EvalError.badVerdict("no recorded verdict for \(request.caseID.rawValue)") }
        return verdict
    }

    static func key(_ rehearsal: RehearsalID, _ caseID: CaseID, _ sample: Int) -> String {
        "\(rehearsal.rawValue)/\(caseID.rawValue)/\(sample)"
    }
}
