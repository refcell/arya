import AryaCore
import Foundation

/// A script for the fake adapter: what to stream and return for each run input.
///
/// The format is documented in docs/PROTOCOL.md ("Fake adapter scripts"). A run whose
/// `input.text` equals a run's `input` uses that run; otherwise the run without `input` is the
/// default; with neither, `run/start` fails with `-32004`.
public struct FakeScript: Sendable, Hashable, Codable {
    public var v: Int
    public var adapter: PeerInfo
    public var capabilities: Capabilities
    public var runs: [Run]

    public static let defaultCapabilities = Capabilities(
        effort: ["low", "medium", "high"], send: true, cost: true, transcript: true,
        tools: .none, sandbox: .workdir)

    public init(
        adapter: PeerInfo = PeerInfo(name: "fake", version: "0.1.0"),
        capabilities: Capabilities = FakeScript.defaultCapabilities, runs: [Run]
    ) {
        self.v = 1
        self.adapter = adapter
        self.capabilities = capabilities
        self.runs = runs
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        adapter =
            try c.decodeIfPresent(PeerInfo.self, forKey: .adapter)
            ?? PeerInfo(name: "fake", version: "0.1.0")
        capabilities =
            try c.decodeIfPresent(Capabilities.self, forKey: .capabilities)
            ?? Self.defaultCapabilities
        runs = try c.decode([Run].self, forKey: .runs)
    }

    enum CodingKeys: String, CodingKey {
        case v, adapter, capabilities, runs
    }

    /// Reads a script file.
    public static func load(from url: URL) throws -> FakeScript {
        try CanonicalJSON.decode(FakeScript.self, from: try Data(contentsOf: url))
    }

    /// The run for `text`: an exact `input` match first, then the default run.
    public func run(for text: String) -> Run? {
        runs.first { $0.input == text } ?? runs.first { $0.input == nil }
    }

    /// What the fake adapter does for one run input.
    public struct Run: Sendable, Hashable, Codable {
        /// The `input.text` this run answers; `nil` makes it the default.
        public var input: String?
        public var steps: [Step]
        public var status: RunStatus
        /// The `run/result` result; `nil` sends no result field.
        public var result: JSONValue?
        public var cost: CostResult
        /// When set, `run/start` fails with this error instead of starting.
        public var startError: RPCError?
        /// When true, `run/stop` is acknowledged but no `run/result` follows (to test kills).
        public var ignoreStop: Bool

        public init(
            input: String? = nil, steps: [Step] = [], status: RunStatus = .completed,
            result: JSONValue? = nil, cost: CostResult = CostResult(),
            startError: RPCError? = nil, ignoreStop: Bool = false
        ) {
            self.input = input
            self.steps = steps
            self.status = status
            self.result = result
            self.cost = cost
            self.startError = startError
            self.ignoreStop = ignoreStop
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            input = try c.decodeIfPresent(String.self, forKey: .input)
            steps = try c.decodeIfPresent([Step].self, forKey: .steps) ?? []
            status = try c.decodeIfPresent(RunStatus.self, forKey: .status) ?? .completed
            result = try c.decodeIfPresent(JSONValue.self, forKey: .result)
            cost = try c.decodeIfPresent(CostResult.self, forKey: .cost) ?? CostResult()
            startError = try c.decodeIfPresent(RPCError.self, forKey: .startError)
            ignoreStop = try c.decodeIfPresent(Bool.self, forKey: .ignoreStop) ?? false
        }

        enum CodingKeys: String, CodingKey {
            case input, steps, status, result, cost, startError, ignoreStop
        }
    }

    /// One scripted step. Exactly one key is set per step on the wire.
    public enum Step: Sendable, Hashable, Codable {
        /// Emit a `run/event`.
        case event(RunEvent)
        /// Wait this many milliseconds.
        case sleep(milliseconds: Int)
        /// Send `host/ask` and wait for the answer, then emit it as a `message` event with
        /// role `human` (an empty text for a `null` answer).
        case ask(question: String, to: String?)
        /// Write this raw text as one stdout line (to test protocol errors).
        case stdout(String)
        /// Exit with this status without sending `run/result`.
        case crash(exitCode: Int32)
        /// Stop producing anything until `run/stop` arrives.
        case hang

        enum CodingKeys: String, CodingKey {
            case event, sleepMs, ask, stdout, crash, hang
        }

        enum AskKeys: String, CodingKey { case question, to }
        enum CrashKeys: String, CodingKey { case exitCode }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let event = try c.decodeIfPresent(RunEvent.self, forKey: .event) {
                self = .event(event)
            } else if let ms = try c.decodeIfPresent(Int.self, forKey: .sleepMs) {
                self = .sleep(milliseconds: ms)
            } else if c.contains(.ask) {
                let ask = try c.nestedContainer(keyedBy: AskKeys.self, forKey: .ask)
                self = .ask(
                    question: try ask.decode(String.self, forKey: .question),
                    to: try ask.decodeIfPresent(String.self, forKey: .to))
            } else if let text = try c.decodeIfPresent(String.self, forKey: .stdout) {
                self = .stdout(text)
            } else if c.contains(.crash) {
                let crash = try c.nestedContainer(keyedBy: CrashKeys.self, forKey: .crash)
                self = .crash(
                    exitCode: try crash.decodeIfPresent(Int32.self, forKey: .exitCode) ?? 1)
            } else if try c.decodeIfPresent(Bool.self, forKey: .hang) == true {
                self = .hang
            } else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "unknown step"))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .event(let event): try c.encode(event, forKey: .event)
            case .sleep(let ms): try c.encode(ms, forKey: .sleepMs)
            case .ask(let question, let to):
                var ask = c.nestedContainer(keyedBy: AskKeys.self, forKey: .ask)
                try ask.encode(question, forKey: .question)
                try ask.encodeIfPresent(to, forKey: .to)
            case .stdout(let text): try c.encode(text, forKey: .stdout)
            case .crash(let code):
                var crash = c.nestedContainer(keyedBy: CrashKeys.self, forKey: .crash)
                try crash.encode(code, forKey: .exitCode)
            case .hang: try c.encode(true, forKey: .hang)
            }
        }
    }
}
