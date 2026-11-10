import AryaCore
import Foundation
import Testing

@testable import AryaAdapters

private func item(_ n: Int, at: String) -> HistoryItem {
    HistoryItem(
        id: "MSG-\(n)", at: at, input: "New message MSG-\(n): Subject",
        actions: [HistoryAction(kind: "route", params: ["queue": "help"], by: "person:sam")],
        choice: "how-to")
}

private let five = [
    item(3, at: "2026-09-03T00:00:00Z"), item(1, at: "2026-09-01T00:00:00Z"),
    item(5, at: "2026-09-05T00:00:00Z"), item(2, at: "2026-09-02T00:00:00Z"),
    item(4, at: "2026-09-04T00:00:00Z"),
]

@Test func historyPagesOldestFirstUntilNoNext() {
    let first = BindingHistory.page(five, HistoryListParams(limit: 2))
    #expect(first.items.map(\.id) == ["MSG-1", "MSG-2"])
    #expect(first.next == "2")
    let second = BindingHistory.page(five, HistoryListParams(cursor: first.next, limit: 2))
    #expect(second.items.map(\.id) == ["MSG-3", "MSG-4"])
    let last = BindingHistory.page(five, HistoryListParams(cursor: second.next, limit: 2))
    #expect(last.items.map(\.id) == ["MSG-5"])
    #expect(last.next == nil)
}

@Test func historyFiltersByTimeWindow() {
    let page = BindingHistory.page(
        five, HistoryListParams(since: "2026-09-02T00:00:00Z", until: "2026-09-04T00:00:00Z"))
    #expect(page.items.map(\.id) == ["MSG-2", "MSG-3"])
    #expect(page.next == nil)
}

@Test func historyClampsLimitAndCursor() {
    #expect(BindingHistory.page(five, HistoryListParams(limit: 0)).items.count == 1)
    #expect(BindingHistory.page(five, HistoryListParams(cursor: "99")).items.isEmpty)
    #expect(BindingHistory.page(five, HistoryListParams(cursor: "x")).items.count == 5)
}

@Test func historyItemWithoutActionsDecodesEmptyAndRoundTrips() throws {
    let json: JSONValue = ["id": "MSG-1", "at": "2026-09-01T00:00:00Z", "input": "New message"]
    let decoded = try json.decode(HistoryItem.self)
    #expect(decoded.actions.isEmpty)
    let full = item(1, at: "2026-09-01T00:00:00Z")
    #expect(try JSONValue(encoding: full).decode(HistoryItem.self) == full)
}

// MARK: Fake binding

private func call(
    _ server: FakeBindingServer, _ method: String, _ params: JSONValue? = nil
) async throws -> Result<JSONValue, RPCError> {
    let reply = await server.handle(
        .request(RPCRequest(id: .int(1), method: method, params: params)))
    guard case .response(let response) = try #require(reply) else {
        throw RPCError(code: RPCErrorCode.internalError, message: "not a response")
    }
    return response.outcome
}

private func tool(_ server: FakeBindingServer, _ name: String, _ arguments: JSONValue)
    async throws -> JSONValue
{
    try await call(server, "tools/call", ["name": .string(name), "arguments": arguments]).get()
}

@Test func fakeBindingServesHistoryGetAndSearch() async throws {
    var records = five
    records[0].record = ["id": "MSG-3", "subject": "Export is slow"]
    let server = FakeBindingServer(data: FakeBindingData(history: records))
    let initialize = try await call(server, "initialize", [:]).get()
    #expect(initialize["serverInfo"]?["name"] == "arya-fake-binding")
    #expect(try await call(server, "ping").get() == [:])
    let names = try await call(server, "tools/list").get()["tools"]?.arrayValue?
        .compactMap { $0["name"]?.stringValue }
    #expect(names == ["history", "outcome", "get", "search"])

    let page = try await tool(server, "history", ["limit": 3])
    #expect(page["isError"] == false)
    let decoded = try #require(page["structuredContent"]).decode(HistoryListResult.self)
    #expect(decoded.items.map(\.id) == ["MSG-1", "MSG-2", "MSG-3"])
    #expect(decoded.next == "3")

    let got = try await tool(server, "get", ["id": "MSG-3"])
    #expect(got["structuredContent"]?["subject"] == "Export is slow")
    #expect(try await tool(server, "get", ["id": "MSG-9"])["isError"] == true)
    let found = try await tool(server, "search", ["query": "EXPORT"])
    #expect(found["structuredContent"]?["items"]?.arrayValue?.count == 1)
    #expect(try await tool(server, "history", ["limit": "many"])["isError"] == true)
}

@Test func fakeBindingRejectsUnknownToolsAndMethods() async throws {
    let server = FakeBindingServer(data: FakeBindingData(history: five))
    let unknownTool = try await call(
        server, "tools/call", ["name": "delete", "arguments": [:]])
    #expect(unknownTool.failureCode == RPCErrorCode.invalidParams)
    #expect(try await call(server, "resources/list").failureCode == RPCErrorCode.methodNotFound)
    let note = RPCMessage.notification(RPCNotification(method: "notifications/initialized"))
    #expect(await server.handle(note) == nil)
}

extension Result where Failure == RPCError {
    fileprivate var failureCode: Int? {
        if case .failure(let error) = self { return error.code }
        return nil
    }
}

// MARK: Triage example

private let triageHistory = repositoryRoot.appendingPathComponent(
    "etc/examples/triage/inbox-history.json")

/// The triage example's past messages carry what an importer needs: a person's routing for
/// every message, ending on the recorded choice, and a few corrections marked `reopened`.
@Test func triageHistoryRecordsWhatAPersonDid() throws {
    let history = try FakeBindingData.load(from: triageHistory).history
    #expect(history.count == 40)
    #expect(Set(history.map(\.id)).count == history.count)
    #expect(history.map(\.at) == history.map(\.at).sorted())
    for entry in history {
        #expect(
            entry.input == "New message \(entry.id): \(entry.record?["subject"]?.stringValue ?? "")"
        )
        #expect(entry.actions.allSatisfy { $0.by?.hasPrefix("person:") == true }, "\(entry.id)")
        let lastLabel = entry.actions.last { $0.kind == "label" }?.params?["label"]?.stringValue
        #expect(lastLabel == entry.choice, "\(entry.id)")
        #expect(entry.outcome != nil, "\(entry.id)")
    }
    let reopened = history.filter { $0.outcome?.status == "reopened" }
    #expect(reopened.count == 5)
    #expect(reopened.allSatisfy { $0.actions.filter { $0.kind == "route" }.count == 2 })
}

/// `arya-fake-adapter --binding` serves the same history over stdio MCP.
@Test func fakeAdapterBinaryServesTheTriageHistory() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: AdapterUnderTest.fakeAdapterPath)
    process.arguments = ["--binding", triageHistory.path]
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    try process.run()
    let lines = [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/call","#
            + #""params":{"name":"history","arguments":{"limit":100}}}"#,
    ]
    input.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    try input.fileHandleForWriting.close()
    let replies = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n")
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(replies.count == 2)
    let page = try JSONDecoder().decode(JSONValue.self, from: Data(try #require(replies.last).utf8))
    let result = try #require(page["result"]?["structuredContent"]).decode(HistoryListResult.self)
    #expect(result.items.count == 40)
    #expect(result.next == nil)
}

/// The triage binding data gives an onboarding run a consistent picture: every queue has an
/// owner in the directory, and every rule and past routing uses a known queue.
@Test func triageDirectoryAndProcessAgree() throws {
    let data = try FakeBindingData.load(from: triageHistory)
    let people = try #require(data.directory)
    let process = try #require(data.process)
    let ids = Set(people.map(\.id))
    let queues = Set(process.queues.map(\.id))
    #expect(process.queues.allSatisfy { $0.owner.map(ids.contains) ?? false })
    #expect(people.allSatisfy { Set($0.queues).isSubset(of: queues) })
    let ruleQueues = process.rules.compactMap { $0.then.params?["queue"]?.stringValue }
    #expect(Set(ruleQueues).isSubset(of: queues))
    let routed = data.history.flatMap(\.actions).compactMap { $0.params?["queue"]?.stringValue }
    #expect(Set(routed).isSubset(of: queues))
    let sources = Set(process.rules.compactMap(\.source))
    #expect(sources.isSubset(of: Set(process.documents.map(\.id))))
    #expect(!process.documents.isEmpty)
}

@Test func triageOutcomesCoverLiveWorkAndHistory() async throws {
    let server = FakeBindingServer(data: try FakeBindingData.load(from: triageHistory))
    let live = try await tool(server, "outcome", ["target": "inbox:MSG-201"])
    #expect(live["structuredContent"]?["status"] == "resolved")
    #expect(live["structuredContent"]?["metric"]?["name"] == "minutes_to_route")
    let past = try await tool(server, "outcome", ["target": "inbox:MSG-004"])
    #expect(past["structuredContent"]?["status"] == "reopened")
    let approvers = try await tool(server, "directory", ["role": "approver"])
    let names = approvers["structuredContent"]?["people"]?.arrayValue?
        .compactMap { $0["id"]?.stringValue }
    #expect(names == ["person:sam", "person:jordan", "person:morgan"])
}
