import AryaCore
import Foundation
import Testing

@testable import AryaAdapters

// MARK: CSV

@Test func csvReadsQuotesCommasNewlinesAndCRLF() {
    let rows = CSV.parse("a,b,c\r\n\"x, y\",\"say \"\"hi\"\"\",\"two\nlines\"\r\n\r\n1,,3")
    #expect(rows == [["a", "b", "c"], ["x, y", "say \"hi\"", "two\nlines"], ["1", "", "3"]])
    #expect(CSV.records("h1,h2\nv1,\n") == [["h1": "v1"]])
}

// MARK: Folder binding

private let folder = Fixtures.url("folder-binding")

private func folderCall(_ tool: String, _ arguments: JSONValue = [:]) throws -> JSONValue {
    try FolderBindingSource(directory: folder).call(tool, arguments)
}

@Test func folderBindingServesEveryFileItFinds() throws {
    let names = try FolderBindingSource(directory: folder).tools().compactMap {
        $0["name"]?.stringValue
    }
    #expect(names == ["history", "outcome", "directory", "process", "get", "search"])
}

@Test func folderHistoryReadsTheCSVExport() throws {
    let page = try folderCall("history").decode(HistoryListResult.self)
    #expect(page.items.map(\.id) == ["T-1", "T-2", "T-3"])
    let refund = try #require(page.items.first { $0.id == "T-2" })
    #expect(refund.input == "New record T-2: Refund, please")
    #expect(refund.record?["body"] == "Charged twice.\nPlease refund one.")
    #expect(refund.record?["subject"] == "Refund, please")
    #expect(refund.record?["by"] == nil)
    #expect(refund.actions.map(\.kind) == ["label", "route"])
    #expect(refund.actions.last?.params == ["queue": "billing"])
    #expect(refund.actions.allSatisfy { $0.by == "person:sam" && $0.target == "inbox:T-2" })
    let bug = try #require(page.items.first { $0.id == "T-1" })
    #expect(bug.outcome == HistoryOutcome(status: "reopened", note: "Rerouted, twice"))
    #expect(bug.record?["subject"] == "The \"export\" button")
    let spam = try #require(page.items.first { $0.id == "T-3" })
    #expect(spam.actions.map(\.kind) == ["label"])
}

@Test func folderOutcomesComeFromTheFileThenTheHistory() throws {
    let live = try folderCall("outcome", ["target": "inbox:LIVE-1"])
        .decode(OutcomeCheckResult.self)
    #expect(live.status == "resolved")
    #expect(
        live.metric
            == OutcomeMetric(name: "minutes_to_route", value: 12, delta: -30, unit: "minutes"))
    #expect(try folderCall("outcome", ["target": "inbox:LIVE-2"])["metric"] == nil)
    let past = try folderCall("outcome", ["target": "inbox:T-1"]).decode(OutcomeCheckResult.self)
    #expect(past.status == "reopened")
    #expect(try folderCall("outcome", ["target": "inbox:NOPE"])["status"] == "unknown")
}

@Test func folderDirectoryAndProcess() throws {
    let all = try folderCall("directory").decode(DirectoryListResult.self).people
    #expect(all.first?.roles == ["triage lead", "approver"])
    #expect(all.first?.queues == ["billing", "help"])
    let approvers = try folderCall("directory", ["role": "approver"])
        .decode(DirectoryListResult.self).people
    #expect(approvers.map(\.id) == ["person:sam"])
    let process = try folderCall("process").decode(ProcessListResult.self)
    #expect(process.rules.first?.then.params == ["queue": "billing"])
    #expect(process.documents.isEmpty)
}

@Test func folderBindingRereadsAndReportsBadFiles() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
        "arya-folder-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = FolderBindingSource(directory: dir)
    #expect(try source.tools().isEmpty)
    #expect(throws: RPCError.self) { try source.call("history", [:]) }
    let line = #"{"id":"J-1","at":"2026-09-01T00:00:00Z","input":"New record J-1"}"#
    try Data((line + "\n").utf8).write(to: dir.appendingPathComponent("history.jsonl"))
    #expect(try source.call("history", [:])["items"]?.arrayValue?.count == 1)
    try Data("{not json".utf8).write(to: dir.appendingPathComponent("process.json"))
    #expect(throws: BindingToolError.self) { try source.tools() }
}

// MARK: HTTP JSON binding

/// Answers requests from fixtures by path and records every request it was sent.
private final class StubHTTP: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [URLRequest] = []
    let answers: [String: (Int, Data)]

    init(_ answers: [String: (Int, Data)]) { self.answers = answers }

    var requests: [URLRequest] { lock.withLock { sent } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { sent.append(request) }
        let path =
            request.url.flatMap {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath
            } ?? ""
        let (status, body) = answers[path] ?? (404, Data("not found".utf8))
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: Fixtures.url("http-json/\(name)"))
}

private func httpSource(_ stub: StubHTTP, token: String? = "s3cret", actions: [String] = [])
    -> HTTPJSONBindingSource
{
    HTTPJSONBindingSource(
        config: HTTPJSONConfig(
            baseURL: URL(string: "https://service.test/api/")!, token: token, actions: actions),
        transport: stub)
}

@Test func httpHistoryPassesTheWindowAndToken() async throws {
    let stub = StubHTTP(["/api/history": (200, try fixture("history.json"))])
    let page = try await httpSource(stub).call(
        "history", ["since": "2026-09-01T00:00:00Z", "limit": 10]
    ).decode(HistoryListResult.self)
    #expect(page.items.map(\.id) == ["H-1"])
    #expect(page.next == "1")
    let request = try #require(stub.requests.first)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.query == "since=2026-09-01T00:00:00Z&limit=10")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer s3cret")
}

@Test func httpConventionToolsCheckTheirShapes() async throws {
    let stub = StubHTTP([
        "/api/outcomes": (200, try fixture("outcome.json")),
        "/api/directory": (200, try fixture("directory.json")),
        "/api/process": (200, try fixture("process.json")),
        "/api/items/MSG%2F1": (200, Data(#"{"id":"MSG/1"}"#.utf8)),
    ])
    let source = httpSource(stub)
    let outcome = try await source.call("outcome", ["target": "inbox:H-1"])
    #expect(outcome["metric"]?["delta"] == 0.5)
    #expect(stub.requests.last?.url?.query == "target=inbox:H-1")
    #expect(try await source.call("directory", ["role": "approver"])["people"] != nil)
    #expect(try await source.call("process", [:])["queues"]?.arrayValue?.count == 1)
    #expect(try await source.call("get", ["id": "MSG/1"])["id"] == "MSG/1")
    #expect(stub.requests.last?.url?.absoluteString == "https://service.test/api/items/MSG%2F1")
}

@Test func httpActionsPostKindTargetAndParams() async throws {
    let stub = StubHTTP(["/api/actions": (200, Data(#"{"ok":true}"#.utf8))])
    let source = httpSource(stub, actions: ["route"])
    let names = source.tools().compactMap { $0["name"]?.stringValue }
    #expect(names == ["history", "outcome", "directory", "process", "list", "get", "route"])
    let answer = try await source.call("route", ["target": "inbox:H-1", "queue": "billing"])
    #expect(answer == ["ok": true])
    let request = try #require(stub.requests.first)
    #expect(request.httpMethod == "POST")
    let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody))
    #expect(body == ["kind": "route", "target": "inbox:H-1", "params": ["queue": "billing"]])
    await #expect(throws: RPCError.self) { try await source.call("delete", [:]) }
}

@Test func httpFailuresSayWhatToFixWithoutTheToken() async throws {
    let stub = StubHTTP([
        "/api/history": (401, Data("bad token s3cret".utf8)),
        "/api/process": (302, Data()),
        "/api/directory": (200, Data(#"{"people":"nobody"}"#.utf8)),
        "/api/outcomes": (500, Data("boom".utf8)),
    ])
    let source = httpSource(stub)
    func message(_ tool: String, _ arguments: JSONValue = [:]) async -> String {
        do {
            _ = try await source.call(tool, arguments)
            return ""
        } catch let error as BindingToolError {
            return error.message
        } catch {
            return "\(error)"
        }
    }
    let refused = await message("history")
    #expect(refused == "GET /api/history was refused (401); check the connection's token")
    #expect(await message("process").contains("does not follow redirects"))
    #expect(await message("directory").contains("unexpected shape"))
    #expect(await message("outcome", ["target": "x"]) == "GET /api/outcomes answered 500: boom")
    #expect(stub.requests.allSatisfy { $0.url?.absoluteString.contains("s3cret") == false })
}

@Test func httpConfigRefusesUnsafeBaseURLs() async {
    func problem(_ url: String) -> String? {
        HTTPJSONConfig(baseURL: URL(string: url)!).problem
    }
    #expect(problem("https://service.test") == nil)
    #expect(problem("http://localhost:8080/api") == nil)
    #expect(problem("http://127.0.0.1:9") == nil)
    #expect(problem("http://service.test")?.contains("https") == true)
    #expect(problem("https://user:pw" + "@" + "service.test")?.contains("credentials") == true)
    let stub = StubHTTP([:])
    let unsafe = HTTPJSONBindingSource(
        config: HTTPJSONConfig(baseURL: URL(string: "http://service.test")!, token: "t"),
        transport: stub)
    await #expect(throws: BindingToolError.self) { try await unsafe.call("process", [:]) }
    #expect(stub.requests.isEmpty)
}

// MARK: arya-binding

private let bindingPath = URL(fileURLWithPath: AdapterUnderTest.fakeAdapterPath)
    .deletingLastPathComponent().appendingPathComponent("arya-binding").path

@Test func aryaBindingServesAFolderOverMCP() async {
    let report = await ConnectionProbe.binding(
        AdapterCommand(executable: bindingPath, arguments: ["folder", folder.path]))
    #expect(report.ok, "\(report.problem ?? "")")
    #expect(report.server?.name == "arya-folder-binding")
    #expect(report.servesHistory)
}

@Test func aryaBindingRefusesAnUnsafeURLBeforeServing() async {
    let report = await ConnectionProbe.binding(
        AdapterCommand(
            executable: bindingPath, arguments: ["http-json", "--base-url", "http://service.test"]))
    #expect(!report.ok)
    #expect(report.problem?.contains("must use https") == true, "\(report.problem ?? "")")
}
