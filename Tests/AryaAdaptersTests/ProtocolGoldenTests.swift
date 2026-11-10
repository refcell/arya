import AryaCore
import Foundation
import Testing

@testable import AryaAdapters

/// One example message from PROTOCOL.md, as stored in `protocol-examples.jsonl`.
struct ProtocolExample: CustomTestStringConvertible, Sendable {
    let name: String
    let method: String
    let message: JSONValue

    var testDescription: String { name }

    static func all() throws -> [ProtocolExample] {
        try Fixtures.jsonLines("protocol-examples.jsonl").map { line in
            ProtocolExample(
                name: line["name"]?.stringValue ?? "?", method: line["method"]?.stringValue ?? "?",
                message: line["message"] ?? .null)
        }
    }
}

/// Decodes `value` as `T`, encodes it again, and returns the result as JSON.
func roundTrip<T: Codable>(_ type: T.Type, _ value: JSONValue) throws -> JSONValue {
    try JSONValue(encoding: try value.decode(type))
}

/// The typed round trip of a request's params or a response's result for `method`.
func typedRoundTrip(method: String, message: RPCMessage) throws -> (JSONValue, JSONValue)? {
    switch message {
    case .request(let request):
        let params = request.params ?? .null
        return (params, try roundTripParams(method: method, params))
    case .notification(let notification):
        let params = notification.params ?? .null
        return (params, try roundTripParams(method: method, params))
    case .response(let response):
        guard case .success(let result) = response.outcome else { return nil }
        return (result, try roundTripResult(method: method, result))
    }
}

func roundTripParams(method: String, _ params: JSONValue) throws -> JSONValue {
    switch method {
    case RPCMethod.initialize: try roundTrip(InitializeParams.self, params)
    case RPCMethod.runStart: try roundTrip(RunStartParams.self, params)
    case RPCMethod.runSend: try roundTrip(RunSendParams.self, params)
    case RPCMethod.runStop: try roundTrip(RunStopParams.self, params)
    case RPCMethod.runTranscript, RPCMethod.runCost: try roundTrip(SessionParams.self, params)
    case RPCMethod.shutdown, RPCMethod.ping: try roundTrip(EmptyObject.self, params)
    case RPCMethod.runEvent: try roundTrip(RunEventParams.self, params)
    case RPCMethod.runResult: try roundTrip(RunResultParams.self, params)
    case RPCMethod.hostAsk: try roundTrip(HostAskParams.self, params)
    case RPCMethod.hostDelegate: try roundTrip(HostDelegateParams.self, params)
    default: throw RPCError(code: RPCErrorCode.methodNotFound, message: method)
    }
}

func roundTripResult(method: String, _ result: JSONValue) throws -> JSONValue {
    switch method {
    case RPCMethod.initialize: try roundTrip(InitializeResult.self, result)
    case RPCMethod.runStart: try roundTrip(RunStartResult.self, result)
    case RPCMethod.runSend, RPCMethod.runStop, RPCMethod.shutdown, RPCMethod.ping:
        try roundTrip(EmptyObject.self, result)
    case RPCMethod.runTranscript: try roundTrip(TranscriptResult.self, result)
    case RPCMethod.runCost: try roundTrip(CostResult.self, result)
    case RPCMethod.hostAsk: try roundTrip(HostAskResult.self, result)
    case RPCMethod.hostDelegate: try roundTrip(HostDelegateResult.self, result)
    default: throw RPCError(code: RPCErrorCode.methodNotFound, message: method)
    }
}

@Test(arguments: try ProtocolExample.all())
func protocolExampleRoundTrips(_ example: ProtocolExample) throws {
    let line = LineCodec.encode(try RPCMessage(json: example.message))
    let message = try LineCodec.decode(line)
    #expect(message.json == example.message)
    if let (original, again) = try typedRoundTrip(method: example.method, message: message) {
        #expect(again == original)
    }
}

@Test func everyMethodHasAnExample() throws {
    let methods = Set(try ProtocolExample.all().map(\.method))
    let expected: Set = [
        RPCMethod.initialize, RPCMethod.runStart, RPCMethod.runSend, RPCMethod.runStop,
        RPCMethod.runTranscript, RPCMethod.runCost, RPCMethod.shutdown, RPCMethod.runEvent,
        RPCMethod.runResult, RPCMethod.hostAsk, RPCMethod.hostDelegate, RPCMethod.ping,
    ]
    #expect(methods == expected)
}

@Test func runResultDecodesTypedFields() throws {
    let example = try #require(try ProtocolExample.all().first { $0.name == "run/result" })
    let params = try #require(example.message["params"]).decode(RunResultParams.self)
    let result = try params.decodedResult()
    #expect(params.status == .completed)
    #expect(result.decisions.map(\.choice) == ["bug"])
    #expect(result.actions.first?.target == "tracker:ISSUE-1")
    #expect(result.measurements.first?.value == 1.5)
}

@Test func absentResultListsDecodeEmpty() throws {
    let result = try (["summary": "done", "extra": true] as JSONValue).decode(RunResult.self)
    #expect(result == RunResult(summary: "done"))
    let empty = try RunResultParams(session: "s1", status: .failed).decodedResult()
    #expect(empty == RunResult())
}

@Test func unknownEventKindKeepsFields() throws {
    let event = try (["kind": "plan", "at": "t", "steps": ["a"]] as JSONValue)
        .decode(RunEvent.self)
    #expect(event.body == RunEvent.Body.other(kind: "plan", fields: ["steps": ["a"]]))
    #expect(event.at == "t")
    #expect(try JSONValue(encoding: event) == ["kind": "plan", "at": "t", "steps": ["a"]])
}

@Test func hostAskNullAnswerIsWritten() throws {
    #expect(try JSONValue(encoding: HostAskResult(answer: nil)) == ["answer": nil])
}

@Test func encodingIsStable() {
    let message = RPCMessage.request(
        RPCRequest(id: .int(1), method: "initialize", params: ["b": 1, "a": "x/y"]))
    let text = String(decoding: LineCodec.encode(message), as: UTF8.self)
    #expect(
        text == #"{"id":1,"jsonrpc":"2.0","method":"initialize","params":{"a":"x/y","b":1}}"#
            + "\n")
}

@Test func lineSplitterHandlesChunksAndCaps() {
    var splitter = LineSplitter(maxLineBytes: 8)
    #expect(splitter.append(Data("ab\ncd".utf8)) == [Data("ab".utf8)])
    #expect(splitter.append(Data("e\n\nf".utf8)) == [Data("cde".utf8), Data()])
    // An over-long line is cut at the cap and its rest dropped up to the next newline.
    #expect(splitter.append(Data("123456789".utf8)) == [Data("f1234567".utf8)])
    #expect(splitter.append(Data("more".utf8)) == [])
    #expect(splitter.append(Data("xx\nok\n".utf8)) == [Data("ok".utf8)])
    #expect(splitter.append(Data("tail".utf8)) == [])
    #expect(splitter.finish() == Data("tail".utf8))
    #expect(splitter.finish() == nil)
}

@Test func cutLineIsAProtocolError() {
    var splitter = LineSplitter(maxLineBytes: 10)
    let lines = splitter.append(Data(#"{"jsonrpc":"2.0","method":"run/event"}"#.utf8 + [0x0A]))
    #expect(lines.count == 1)
    #expect(throws: RPCError.self) { try LineCodec.decode(lines[0]) }
}

@Test func runResultCarriesPlanRiskAndWhy() throws {
    let example = try #require(
        try ProtocolExample.all().first { $0.name == "run/result with plan" })
    let raw = try #require(example.message["params"]?["result"])
    let result = try raw.decode(RunResult.self)
    #expect(result.plan.map(\.status) == [.done, .done, .inProgress, .skipped])
    #expect(result.plan[3].rationale == "none found")
    #expect(result.decisions.first?.why == "The app crashes on save.")
    #expect(result.actions.map(\.risk) == [.low, .medium])
    #expect(result.actions.allSatisfy { $0.why != nil })
    // The typed round trip keeps every field.
    #expect(try JSONValue(encoding: result) == raw)
    // A plan is omitted when empty, so results without one encode as before.
    #expect(try JSONValue(encoding: RunResult(summary: "s"))["plan"] == nil)
    let badRisk: JSONValue = ["actions": [["id": "a1", "kind": "label", "risk": "extreme"]]]
    #expect(throws: (any Error).self) { try badRisk.decode(RunResult.self) }
}
