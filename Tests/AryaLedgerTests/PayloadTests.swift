import AryaCore
import Foundation
import Testing

@testable import AryaLedger

/// One sample of a payload type, type-erased for the golden table.
struct PayloadSample: Sendable, CustomStringConvertible {
    let type: EventType
    let encode: @Sendable () throws -> JSONValue
    let roundTrips: @Sendable (Data) throws -> Bool

    init<P: EventPayload>(_ value: P) {
        type = P.type
        encode = { try CanonicalJSON.jsonValue(value) }
        roundTrips = { try JSONDecoder().decode(P.self, from: $0) == value }
    }

    var description: String { type.rawValue }
}

let payloadSamples: [PayloadSample] = [
    PayloadSample(EnvRead(readings: [.time(Timestamp(millis: 0)), .random(42)])),
    PayloadSample(
        SystemRepair(
            segment: "000001.jsonl", offset: 4096, length: 17,
            blob: String(repeating: "ef", count: 32), reason: "no trailing newline")),
    PayloadSample(SystemStarted(process: "test", version: "0.1.0")),
]

private func goldenName(_ type: EventType) -> String { "payloads/\(type.rawValue).json" }

@Test(arguments: payloadSamples)
func payloadGolden(_ sample: PayloadSample) throws {
    let text = try CanonicalJSON.string(sample.encode())
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let url = dir.appendingPathComponent("Fixtures").appendingPathComponent(goldenName(sample.type))
    if ProcessInfo.processInfo.environment["ARYA_UPDATE_GOLDENS"] == "1" {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((text + "\n").utf8).write(to: url)
    }
    #expect(text == (try fixtureText(goldenName(sample.type))))
    #expect(try sample.roundTrips(Data(text.utf8)))
    #expect(try sample.encode()["v"] == 1)
}

@Test func everyLedgerOwnedTypeHasAPayload() {
    // Other payloads live with their writer (decisions 0019, 0022, 0023).
    let owned: Set<EventType> = [.envRead, .systemRepair, .systemStarted]
    #expect(Set(payloadSamples.map(\.type)) == owned)
}

@Test func typedPayloadAccess() throws {
    let draft = try EventDraft(SystemStarted(process: "test", version: "0.1.0"), actor: .system)
    let (event, _) = try LedgerLine.seal(
        draft, seq: 1, prev: Event.genesisHash, id: EventID(rawValue: "ev_1")!,
        at: Timestamp(millis: 0))
    #expect(try event.payload(as: SystemStarted.self).process == "test")
    #expect(throws: LedgerError.self) { try event.payload(as: EnvRead.self) }
}
