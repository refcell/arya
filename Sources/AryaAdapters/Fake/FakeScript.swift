import AryaCore
import Foundation

/// A script for the fake adapter: what to stream and return for each run input.
///
/// The format is documented in docs/PROTOCOL.md ("Fake adapter scripts"). `responses` maps the
/// exact `run/start.input.text` to a response; other inputs get `default`; with neither,
/// `run/start` fails with `-32004`. The equivalent list form `runs` (entries with an optional
/// `input`) is read too; when both name an input, `responses` wins.
public struct FakeScript: Sendable, Hashable, Codable {
    public var v: Int
    public var adapter: PeerInfo
    public var capabilities: Capabilities
    public var responses: [String: Response]
    public var defaultResponse: Response?

    public static let defaultAdapter = PeerInfo(name: "fake", version: "0.1.0")

    public static let defaultCapabilities = Capabilities(
        effort: ["low", "medium", "high"], send: true, cost: true, transcript: true,
        tools: .none, sandbox: .workdir)

    public init(
        adapter: PeerInfo = FakeScript.defaultAdapter,
        capabilities: Capabilities = FakeScript.defaultCapabilities,
        responses: [String: Response] = [:], defaultResponse: Response? = nil
    ) {
        self.v = 1
        self.adapter = adapter
        self.capabilities = capabilities
        self.responses = responses
        self.defaultResponse = defaultResponse
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        adapter = try c.decodeIfPresent(PeerInfo.self, forKey: .adapter) ?? Self.defaultAdapter
        capabilities =
            try c.decodeIfPresent(Capabilities.self, forKey: .capabilities)
            ?? Self.defaultCapabilities
        responses = try c.decodeIfPresent([String: Response].self, forKey: .responses) ?? [:]
        defaultResponse = try c.decodeIfPresent(Response.self, forKey: .defaultResponse)
        // The list form: each run carries its `input`; the run without one is the default.
        for run in try c.decodeIfPresent([ListedRun].self, forKey: .runs) ?? [] {
            if let input = run.input {
                responses[input] = responses[input] ?? run.response
            } else {
                defaultResponse = defaultResponse ?? run.response
            }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(adapter, forKey: .adapter)
        try c.encode(capabilities, forKey: .capabilities)
        try c.encode(responses, forKey: .responses)
        try c.encodeIfPresent(defaultResponse, forKey: .defaultResponse)
    }

    /// One entry of the list form `runs`: a response plus the input it answers.
    private struct ListedRun: Decodable {
        var input: String?
        var response: Response

        enum CodingKeys: String, CodingKey { case input }

        init(from decoder: any Decoder) throws {
            input = try decoder.container(keyedBy: CodingKeys.self)
                .decodeIfPresent(String.self, forKey: .input)
            response = try Response(from: decoder)
        }
    }

    enum CodingKeys: String, CodingKey {
        case v, adapter, capabilities, responses, runs
        case defaultResponse = "default"
    }

    /// A script in the list form: each run answers its `input`; the run without one is the
    /// default. When two runs name the same input, the first wins.
    public init(
        adapter: PeerInfo = FakeScript.defaultAdapter,
        capabilities: Capabilities = FakeScript.defaultCapabilities, runs: [Run]
    ) {
        self.init(adapter: adapter, capabilities: capabilities)
        for run in runs {
            if let input = run.input {
                responses[input] = responses[input] ?? run.response
            } else {
                defaultResponse = defaultResponse ?? run.response
            }
        }
    }

    /// One run of the list form: a response and the input it answers.
    public struct Run: Sendable, Hashable {
        /// The `input.text` this run answers; `nil` makes it the default.
        public var input: String?
        public var response: Response

        public init(
            input: String? = nil, steps: [Step] = [], status: RunStatus = .completed,
            result: JSONValue? = nil, cost: CostResult = CostResult(),
            startError: RPCError? = nil, ignoreStop: Bool = false
        ) {
            self.input = input
            self.response = Response(
                steps: steps, status: status, result: result, cost: cost,
                startError: startError, ignoreStop: ignoreStop)
        }
    }

    /// Reads a script file.
    public static func load(from url: URL) throws -> FakeScript {
        try CanonicalJSON.decode(FakeScript.self, from: try Data(contentsOf: url))
    }

    /// The response for `text`: its exact entry, else the default.
    public func response(for text: String) -> Response? {
        responses[text] ?? defaultResponse
    }

    /// What the fake adapter does for one run input. Only `events`, `status`, and `result`
    /// are needed for ordinary scripts; the other fields script failures and timing.
    public struct Response: Sendable, Hashable, Codable {
        /// Events emitted first, in order (`seq` is assigned by the adapter).
        public var events: [RunEvent]
        /// Steps run after `events`.
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
            events: [RunEvent] = [], steps: [Step] = [], status: RunStatus = .completed,
            result: JSONValue? = nil, cost: CostResult = CostResult(),
            startError: RPCError? = nil, ignoreStop: Bool = false
        ) {
            self.events = events
            self.steps = steps
            self.status = status
            self.result = result
            self.cost = cost
            self.startError = startError
            self.ignoreStop = ignoreStop
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            events = try c.decodeIfPresent([RunEvent].self, forKey: .events) ?? []
            steps = try c.decodeIfPresent([Step].self, forKey: .steps) ?? []
            status = try c.decodeIfPresent(RunStatus.self, forKey: .status) ?? .completed
            result = try c.decodeIfPresent(JSONValue.self, forKey: .result)
            cost = try c.decodeIfPresent(CostResult.self, forKey: .cost) ?? CostResult()
            startError = try c.decodeIfPresent(RPCError.self, forKey: .startError)
            ignoreStop = try c.decodeIfPresent(Bool.self, forKey: .ignoreStop) ?? false
        }

        enum CodingKeys: String, CodingKey {
            case events, steps, status, result, cost, startError, ignoreStop
        }

        /// `events` followed by `steps`, as the adapter performs them.
        var allSteps: [Step] { events.map { .event($0) } + steps }
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
