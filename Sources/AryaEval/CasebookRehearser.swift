import AryaCore
import AryaRuntime

/// One rehearsal run to perform: a case, sampled once, under the given charter version.
public struct CaseRunRequest: Hashable, Sendable {
    public var steward: StewardID
    public var charterVersion: Int
    /// The charter the run uses (live or a proposal's candidate).
    public var charter: Charter
    public var rehearsal: RehearsalID
    public var caseItem: Case
    /// Sample index, starting at 0.
    public var sample: Int
}

/// What a rehearsal run produced.
public struct CaseRunOutcome: Hashable, Sendable {
    public var run: RunID?
    /// The run's result in the shape of a case's `expected` (`decisions`, `actions`, ...).
    public var result: JSONValue
    /// True when a tool read had no answer in the case's recorded context.
    public var leak: Bool

    public init(run: RunID?, result: JSONValue, leak: Bool = false) {
        self.run = run
        self.result = result
        self.leak = leak
    }
}

/// Starts one run with trigger kind `case`: tool reads are answered from the case context and
/// no action is executed (decision 0015). The runtime implements it; the facade wires it.
public protocol CaseRunner: Sendable {
    func run(_ request: CaseRunRequest) async throws -> CaseRunOutcome
}

/// Looks up an imported casebook by version.
public protocol CasebookSource: Sendable {
    func casebook(version: String) async throws -> Casebook
}

/// Rehearses a steward on a casebook: every case `samples` times, at most `maxParallel` runs
/// at once. Events (actor `system`) are recorded after all runs finish, in case-id order, so
/// the ledger order does not depend on which run finished first. A run that throws scores 0
/// for that sample.
public struct CasebookRehearser: Rehearser {
    public var runner: any CaseRunner
    public var casebooks: any CasebookSource
    public var scorer: any Scorer
    public var sink: any EventSink
    public var ambient: Ambient
    public var maxParallel: Int

    public init(
        runner: any CaseRunner, casebooks: any CasebookSource, scorer: any Scorer,
        sink: any EventSink, ambient: Ambient, maxParallel: Int = 1
    ) {
        self.runner = runner
        self.casebooks = casebooks
        self.scorer = scorer
        self.sink = sink
        self.ambient = ambient
        self.maxParallel = max(1, maxParallel)
    }

    public func rehearse(
        _ request: RehearsalRequest, charter: Charter
    ) async throws -> RehearsalResult {
        let book = try await casebooks.casebook(version: request.casebookVersion)
        let id = ambient.newID(RehearsalID.self)
        try await record(
            EvalEventType.rehearsalStarted, request.steward,
            RehearsalStartedPayload(
                rehearsal: id, charterVersion: request.charterVersion,
                casebookVersion: book.version, cases: book.cases.count,
                samples: request.samples, proposal: request.proposal))
        let jobs = book.cases.flatMap { item in
            (0..<request.samples).map {
                CaseRunRequest(
                    steward: request.steward, charterVersion: request.charterVersion,
                    charter: charter, rehearsal: id, caseItem: item, sample: $0)
            }
        }
        let done = await runAll(jobs)
        var outcomes: [CaseOutcome] = []
        for (index, item) in book.cases.enumerated() {
            let slice = done[(index * request.samples)..<((index + 1) * request.samples)]
            let outcome = CaseOutcome(
                caseID: item.id, samples: slice.map(\.score), leak: slice.contains { $0.leak })
            outcomes.append(outcome)
            try await record(
                EvalEventType.rehearsalCaseScored, request.steward,
                RehearsalCaseScoredPayload(
                    rehearsal: id, caseID: item.id, runs: slice.map(\.run),
                    scores: outcome.samples, leak: outcome.leak))
        }
        let result = RehearsalResult(id: id, request: request, outcomes: outcomes)
        try await record(
            EvalEventType.rehearsalFinished, request.steward,
            RehearsalFinishedPayload(
                rehearsal: id, meanScore: GateRule.mean(result),
                passed: outcomes.filter(GateRule.alwaysPassed).count,
                leaks: outcomes.filter(\.leak).count))
        return result
    }

    struct Done: Sendable {
        var run: RunID?
        var score: CaseScore
        var leak: Bool
    }

    /// Runs every job with bounded parallelism and returns results in job order.
    func runAll(_ jobs: [CaseRunRequest]) async -> [Done] {
        var results = [Done?](repeating: nil, count: jobs.count)
        await withTaskGroup(of: (Int, Done).self) { group in
            var next = 0
            func launch() {
                guard next < jobs.count else { return }
                let index = next
                next += 1
                group.addTask { (index, await runOne(jobs[index])) }
            }
            for _ in 0..<min(maxParallel, jobs.count) { launch() }
            while let (index, done) = await group.next() {
                results[index] = done
                launch()
            }
        }
        return results.compactMap { $0 }
    }

    func runOne(_ job: CaseRunRequest) async -> Done {
        do {
            let outcome = try await runner.run(job)
            var score = scorer.score(expected: job.caseItem.expected, actual: outcome.result)
            if outcome.leak {
                score = CaseScore(value: 0, passed: false, notes: score.notes + ["leak"])
            }
            return Done(run: outcome.run, score: score, leak: outcome.leak)
        } catch {
            let note = "run failed: \(String(describing: error))"
            return Done(
                run: nil, score: CaseScore(value: 0, passed: false, notes: [note]), leak: false)
        }
    }

    func record(_ type: String, _ steward: StewardID, _ payload: some Encodable) async throws {
        _ = try await sink.append(
            RuntimeEventDraft(
                type: type, steward: steward, actor: .system,
                payload: try CanonicalJSON.jsonValue(payload)))
    }
}
