import AryaCore
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

func makeNote(_ id: NoteID, _ text: String, tags: [String] = [], run: RunID? = "run_1")
    throws -> MemoryNote
{
    try MemoryNote(
        id: id, text: text, tags: tags,
        provenance: MemoryProvenance(
            run: run, event: EventID(unchecked: "ev_\(id.body)"), author: stewardAuthor()))
}

func addedEvent(seq: Int, steward: StewardID = "st_triage", note: MemoryNote) throws
    -> MemoryEventRecord
{
    let payload = try JSONEncoder().encode(MemoryAddedPayload(note: note))
    return MemoryEventRecord(
        seq: seq, id: EventID(unchecked: "ev_\(seq)"), steward: steward,
        type: MemoryEventType.added,
        payload: payload)
}

func retractedEvent(seq: Int, steward: StewardID = "st_triage", note: NoteID) throws
    -> MemoryEventRecord
{
    let payload = try JSONEncoder().encode(MemoryRetractedPayload(note: note, reason: "stale"))
    return MemoryEventRecord(
        seq: seq, id: EventID(unchecked: "ev_\(seq)"), steward: steward,
        type: MemoryEventType.retracted,
        payload: payload)
}

/// Literal ids keep fixtures readable. Test-only; library code validates ids.
extension NoteID: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self.init(unchecked: value) }
}

extension StewardID: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self.init(unchecked: value) }
}

extension RunID: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self.init(unchecked: value) }
}

extension EventID: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self.init(unchecked: value) }
}

extension CaseID: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        guard let id = CaseID(rawValue: value) else { fatalError("bad case id \(value)") }
        self = id
    }
}
