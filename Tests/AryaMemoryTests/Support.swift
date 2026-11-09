import Foundation
import Testing

@testable import AryaMemory

/// Deterministic JSON: sorted keys, no whitespace, `/` unescaped.
func encodeJSON(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

/// Contents of `Fixtures/<name>`, without the trailing newline.
func fixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent(name)
    let text = try String(contentsOf: url, encoding: .utf8)
    return text.hasSuffix("\n") ? String(text.dropLast()) : text
}

func stewardAuthor(_ id: String = "st_triage") -> MemoryAuthor {
    MemoryAuthor(kind: .steward, id: id)
}

func makeNote(_ id: String, _ text: String, tags: [String] = [], run: String? = "run_1")
    throws -> MemoryNote
{
    try MemoryNote(
        id: id, text: text, tags: tags,
        provenance: MemoryProvenance(run: run, event: "ev_\(id)", author: stewardAuthor()))
}

func addedEvent(seq: Int, steward: String = "st_triage", note: MemoryNote) throws
    -> MemoryEventRecord
{
    let payload = try JSONEncoder().encode(MemoryAddedPayload(note: note))
    return MemoryEventRecord(
        seq: seq, id: "ev_\(seq)", steward: steward, type: MemoryEventType.added,
        payload: payload)
}

func retractedEvent(seq: Int, steward: String = "st_triage", note: String) throws
    -> MemoryEventRecord
{
    let payload = try JSONEncoder().encode(MemoryRetractedPayload(note: note, reason: "stale"))
    return MemoryEventRecord(
        seq: seq, id: "ev_\(seq)", steward: steward, type: MemoryEventType.retracted,
        payload: payload)
}
