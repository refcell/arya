import AryaCore
import Foundation

/// The records a ``FakeBindingServer`` serves:
/// `{"v":1,"history":[…],"outcomes":[…],"directory":[…],"process":{…}}`. Only `history` is
/// required.
public struct FakeBindingData: Sendable, Hashable, Codable {
    public var v: Int
    public var history: [HistoryItem]
    /// Outcomes for targets the history does not cover, such as live work after the import.
    public var outcomes: [OutcomeCheckResult]
    public var directory: [DirectoryPerson]?
    public var process: ProcessListResult?

    public init(
        v: Int = 1, history: [HistoryItem], outcomes: [OutcomeCheckResult] = [],
        directory: [DirectoryPerson]? = nil, process: ProcessListResult? = nil
    ) {
        self.v = v
        self.history = history
        self.outcomes = outcomes
        self.directory = directory
        self.process = process
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        history = try c.decode([HistoryItem].self, forKey: .history)
        outcomes = try c.decodeIfPresent([OutcomeCheckResult].self, forKey: .outcomes) ?? []
        directory = try c.decodeIfPresent([DirectoryPerson].self, forKey: .directory)
        process = try c.decodeIfPresent(ProcessListResult.self, forKey: .process)
    }

    public static func load(from url: URL) throws -> FakeBindingData {
        try JSONDecoder().decode(FakeBindingData.self, from: Data(contentsOf: url))
    }

    enum CodingKeys: String, CodingKey {
        case v, history, outcomes, directory, process
    }
}

/// The ``BindingSource`` of the fake binding: the convention tools answered from
/// ``FakeBindingData``.
public struct FakeBindingSource: BindingSource {
    private let records: RecordSet

    public init(data: FakeBindingData) {
        records = RecordSet(
            history: data.history, outcomes: data.outcomes, directory: data.directory,
            process: data.process)
    }

    public var serverName: String { "arya-fake-binding" }

    public func tools() -> [JSONValue] { records.toolNames.map(BindingTools.descriptor) }

    public func call(_ tool: String, _ arguments: JSONValue) throws -> JSONValue {
        try records.call(tool, arguments)
    }
}

/// A deterministic MCP binding server, for tests, the demo, and importer and onboarding
/// development: `history`, `outcome`, `directory`, `process`, `get`, and `search` from
/// ``FakeBindingData`` (the tools its data supports). `arya-fake-adapter --binding <file>` runs
/// it.
public actor FakeBindingServer {
    private let server: BindingServer

    public init(data: FakeBindingData) {
        server = BindingServer(source: FakeBindingSource(data: data))
    }

    /// Serves until the client closes the connection.
    public func serve(_ endpoint: any AdapterEndpoint) async {
        await server.serve(endpoint)
    }

    /// The reply to one message; notifications and responses get none.
    public func handle(_ message: RPCMessage) async -> RPCMessage? {
        await server.handle(message)
    }
}
