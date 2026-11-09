import AryaAdapters
import AryaCore
import Foundation
import Testing

@testable import AryaRuntime

private let tracker = CharterBinding.mcp(
    "tracker", command: "tracker-mcp", read: ["get", "search"], actions: ["label"])

private actor FakeUpstream: ToolUpstream {
    private(set) var calls: [String] = []

    func listTools() async throws -> [JSONValue] {
        ["get", "search", "update"].map {
            [
                "name": .string($0), "description": .string("tracker \($0)"),
                "inputSchema": ["type": "object"],
            ]
        }
    }

    func call(_ tool: String, arguments: JSONValue) async throws -> JSONValue {
        calls.append(tool)
        return BindingProxy.result(
            ["id": arguments["id"] ?? .null, "title": "Login times out"], isError: false)
    }
}

private func request(_ id: Int64, _ method: String, _ params: JSONValue? = nil) -> RPCMessage {
    .request(RPCRequest(id: .int(id), method: method, params: params))
}

private func result(_ reply: RPCMessage?) throws -> JSONValue {
    guard case .response(let response)? = reply, case .success(let value) = response.outcome
    else { throw RPCError(code: 0, message: "not a result: \(String(describing: reply))") }
    return value
}

private struct ProxyRig {
    let sink = MemoryEventSink(ambient: .fixed())
    let upstream = FakeUpstream()
    let run = RunID(unchecked: "run_01")

    func proxy(_ source: ToolSource? = nil) -> BindingProxy {
        BindingProxy(
            binding: tracker, source: source ?? .live(upstream),
            recorder: ToolCallRecorder(
                sink: sink, steward: StewardID(unchecked: "st_triage"), run: run))
    }

    func types() async throws -> [String] { try await sink.events(from: 1).map(\.type) }
}

@Test func proxyListsOnlyReadTools() async throws {
    let rig = ProxyRig()
    let listed = try result(await rig.proxy().handle(request(1, "tools/list")))
    #expect(
        listed["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == ["get", "search"])
    let initialized = try result(await rig.proxy().handle(request(2, "initialize", [:])))
    #expect(initialized["capabilities"]?["tools"] == [:])
}

@Test func readCallsGoUpstreamAndAreRecorded() async throws {
    let rig = ProxyRig()
    let answer = try result(
        await rig.proxy().handle(
            request(7, "tools/call", ["name": "get", "arguments": ["id": "ISSUE-7"]])))
    #expect(answer["structuredContent"]?["title"] == "Login times out")
    #expect(answer["isError"] == false)
    #expect(await rig.upstream.calls == ["get"])

    let events = try await rig.sink.events(from: 1)
    #expect(events.map(\.type) == ["run.tool.call", "run.tool.result"])
    #expect(events[0].payload["id"] == "tracker:7")
    #expect(events[0].payload["binding"] == "tracker")
    #expect(events[0].payload["tool"] == "get")
    #expect(events[0].payload["input"] == ["id": "ISSUE-7"])
    #expect(events[1].payload["output"]?["title"] == "Login times out")
    #expect(events.allSatisfy { $0.draft.run == rig.run })
}

@Test func writeAndUnknownToolsAreRefusedUnrecorded() async throws {
    let rig = ProxyRig()
    for name in ["update", "delete"] {
        let reply = try await rig.proxy().handle(
            request(3, "tools/call", ["name": .string(name), "arguments": [:]]))
        guard case .response(let response)? = reply, case .failure(let error) = response.outcome
        else {
            Issue.record("expected an error for \(name)")
            continue
        }
        #expect(error.code == RPCErrorCode.invalidParams)
    }
    #expect(await rig.upstream.calls.isEmpty)
    #expect(try await rig.types().isEmpty)
}

@Test func recordedSourceAnswersFromRecordingsAndFlagsLeaks() async throws {
    let rig = ProxyRig()
    let proxy = rig.proxy(
        .recorded([
            RecordedToolResult(
                tool: "tracker.get", input: ["id": "ISSUE-7"], output: ["title": "Recorded"])
        ]))
    let hit = try result(
        await proxy.handle(
            request(1, "tools/call", ["name": "get", "arguments": ["id": "ISSUE-7"]])))
    #expect(hit["structuredContent"]?["title"] == "Recorded")
    #expect(await !proxy.leak)

    let miss = try result(
        await proxy.handle(
            request(2, "tools/call", ["name": "get", "arguments": ["id": "ISSUE-8"]])))
    #expect(miss["isError"] == true)
    #expect(await proxy.leak)
    #expect(await rig.upstream.calls.isEmpty)
    #expect(try await rig.types().count == 4)
}

@Test func proxyServesNewlineDelimitedJSONRPC() async throws {
    let rig = ProxyRig()
    let (input, feed) = AsyncStream<Data>.makeStream()
    let replies = Lines()
    let messages = [
        request(1, "initialize", [:]),
        .notification(RPCNotification(method: "notifications/initialized")),
        request(2, "tools/list"),
    ]
    var bytes = Data()
    for message in messages { bytes.append(LineCodec.encode(message)) }
    // Split mid-line to exercise buffering, and send one line that is not JSON.
    feed.yield(bytes.prefix(10))
    feed.yield(bytes.dropFirst(10))
    feed.yield(Data("not json\n".utf8))
    feed.finish()
    await rig.proxy().serve(input) { await replies.add($0) }
    let decoded = await replies.all.map {
        try? LineCodec.decode($0.last == 0x0A ? $0.dropLast() : $0)
    }
    #expect(decoded.count == 2)
    guard case .response(let second)? = decoded.last else {
        Issue.record("expected a response")
        return
    }
    #expect(second.id == .int(2))
}

private actor Lines {
    private(set) var all: [Data] = []
    func add(_ line: Data) { all.append(line) }
}

@Test func recordedCallsReplayFromTheLedger() async throws {
    let rig = ProxyRig()
    _ = try await rig.proxy().handle(
        request(1, "tools/call", ["name": "get", "arguments": ["id": "ISSUE-7"]]))
    let recordings = try ToolRecordings.from(try await rig.sink.events(from: 1), run: rig.run)
    #expect(recordings.count == 1)
    #expect(recordings[0].tool == "tracker.get")
    #expect(recordings[0].input == ["id": "ISSUE-7"])

    // A replay proxy answers the same call identically, with no upstream and no leak.
    let replay = rig.proxy(.recorded(recordings))
    let answer = try result(
        await replay.handle(
            request(1, "tools/call", ["name": "get", "arguments": ["id": "ISSUE-7"]])))
    #expect(answer["structuredContent"]?["title"] == "Login times out")
    #expect(await !replay.leak)
    #expect(await rig.upstream.calls == ["get"])
}
