import AryaAdapters
import AryaCore
import AryaLedger
import Foundation

// Live steps (decision 0049). The raw wire lines of a run (`run.adapter.event`) are the record
// replay needs; these events are the run's progress as the app shows it while it happens. A
// tool call opens a step (`run.step.started`), its output arrives as numbered chunks
// (`run.step.output`), and its result closes it (`run.step.finished`). An adapter that streams
// output sends `tool_output` events (`id`, `text`) before the `tool_result`; each becomes a
// chunk as it arrives. Output past `StepText.inlineLimit` goes to a blob, and the event keeps
// a short preview, so the ledger stays compact.

/// Event types of a run's live steps.
public enum StepEventType {
    /// `run.step.started`.
    public static let started = EventType("run.step.started")
    /// `run.step.output`.
    public static let output = EventType("run.step.output")
    /// `run.step.finished`.
    public static let finished = EventType("run.step.finished")
}

/// `run.step.started`: the agent called a tool (actor: the adapter).
public struct StepStarted: Sendable, Hashable, Codable {
    /// The tool call's id, unique within the run.
    public var step: String
    /// The tool.
    public var tool: String
    /// The call's input, cut to `StepText.previewBytes` when long.
    public var input: String
    /// True when `input` was cut.
    public var truncated: Bool?

    /// Creates the payload.
    public init(step: String, tool: String, input: String, truncated: Bool? = nil) {
        self.step = step
        self.tool = tool
        self.input = input
        self.truncated = truncated
    }
}

/// `run.step.output`: one chunk of a step's output, numbered from 1 within the step. A chunk
/// holds `text`, or, when the output was too long to keep inline, `blob` (the full output's
/// key in the home's blob store) with `text` as its preview.
public struct StepOutput: Sendable, Hashable, Codable {
    /// The step.
    public var step: String
    /// The chunk's number within the step, from 1.
    public var seq: Int
    /// The chunk, or the preview of a blob.
    public var text: String
    /// The blob holding the whole output, when it was too long to keep inline.
    public var blob: String?
    /// Size in bytes of the chunk, or of the whole output for a blob.
    public var bytes: Int
    /// True when the output was cut and no blob store was available.
    public var truncated: Bool?

    /// Creates the payload.
    public init(
        step: String, seq: Int, text: String, blob: String? = nil, bytes: Int,
        truncated: Bool? = nil
    ) {
        self.step = step
        self.seq = seq
        self.text = text
        self.blob = blob
        self.bytes = bytes
        self.truncated = truncated
    }
}

/// `run.step.finished`: the tool answered.
public struct StepFinished: Sendable, Hashable, Codable {
    /// The step.
    public var step: String
    /// False when the tool reported an error.
    public var ok: Bool
    /// Output size in bytes.
    public var bytes: Int
    /// How many `run.step.output` chunks the step recorded.
    public var chunks: Int
    /// Milliseconds from the step's start, by the runtime's clock.
    public var millis: Int64

    /// Creates the payload.
    public init(step: String, ok: Bool, bytes: Int, chunks: Int, millis: Int64) {
        self.step = step
        self.ok = ok
        self.bytes = bytes
        self.chunks = chunks
        self.millis = millis
    }
}

/// How step text is cut into chunks and previews.
public enum StepText {
    /// Largest chunk, in UTF-8 bytes.
    public static let chunkBytes = 4096
    /// Output up to this size is kept inline as chunks; longer output goes to a blob.
    public static let inlineLimit = 16384
    /// Size of a preview (a blob's or a long input's), in UTF-8 bytes.
    public static let previewBytes = 1024

    /// Tool input or output as text: a string as is, anything else as canonical JSON.
    public static func text(_ value: JSONValue) -> String {
        if case .string(let text) = value { return text }
        guard let data = try? CanonicalJSON.encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// `text` in pieces of at most `limit` UTF-8 bytes, never splitting a character. Empty text
    /// gives no pieces.
    public static func chunks(_ text: String, limit: Int = chunkBytes) -> [String] {
        var pieces: [String] = []
        var current = ""
        var size = 0
        for character in text {
            let width = character.utf8.count
            if size + width > limit, !current.isEmpty {
                pieces.append(current)
                current = ""
                size = 0
            }
            current.append(character)
            size += width
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    /// The first `limit` UTF-8 bytes of `text` (whole characters) and whether it was cut.
    public static func preview(_ text: String, limit: Int = previewBytes) -> (String, Bool) {
        guard text.utf8.count > limit else { return (text, false) }
        return (chunks(text, limit: limit).first ?? "", true)
    }
}

/// Turns one run's adapter events into step events. Confined to the run's driver.
struct StepRecorder {
    private struct Open {
        var started: Timestamp
        var chunks = 0
        var bytes = 0
    }

    private var open: [String: Open] = [:]

    /// The step drafts `event` adds, in order; `now` stamps durations and `putBlob` stores
    /// long output (nil when the sink keeps no blobs).
    mutating func drafts(
        for event: RunEvent, now: Timestamp, putBlob: (Data) async throws -> String?
    ) async throws -> [(EventType, JSONValue)] {
        switch event.body {
        case .toolCall(let id, let tool, let input):
            open[id] = Open(started: now)
            let (text, cut) = StepText.preview(StepText.text(input))
            let payload = StepStarted(
                step: id, tool: tool, input: text, truncated: cut ? true : nil)
            return [(StepEventType.started, try Payload.encode(payload))]
        case .other(kind: "tool_output", let fields):
            guard case .string(let id)? = fields["id"], case .string(let text)? = fields["text"],
                open[id] != nil
            else { return [] }
            return try chunkDrafts(id, text)
        case .toolResult(let id, let output, let isError):
            guard var step = open.removeValue(forKey: id) else { return [] }
            var drafts: [(EventType, JSONValue)] = []
            if step.chunks == 0 {
                open[id] = step
                drafts = try await outputDrafts(id, StepText.text(output), putBlob: putBlob)
                step = open.removeValue(forKey: id) ?? step
            }
            let finished = StepFinished(
                step: id, ok: !isError, bytes: step.bytes, chunks: step.chunks,
                millis: max(0, now.millis - step.started.millis))
            drafts.append((StepEventType.finished, try Payload.encode(finished)))
            return drafts
        default:
            return []
        }
    }

    /// Chunks of streamed text for an open step.
    private mutating func chunkDrafts(_ id: String, _ text: String) throws -> [(
        EventType, JSONValue
    )] {
        var drafts: [(EventType, JSONValue)] = []
        for piece in StepText.chunks(text) {
            open[id]?.chunks += 1
            open[id]?.bytes += piece.utf8.count
            let output = StepOutput(
                step: id, seq: open[id]?.chunks ?? 1, text: piece, bytes: piece.utf8.count)
            drafts.append((StepEventType.output, try Payload.encode(output)))
        }
        return drafts
    }

    /// A step's whole output: inline chunks, or one blob chunk with a preview.
    private mutating func outputDrafts(
        _ id: String, _ text: String, putBlob: (Data) async throws -> String?
    ) async throws -> [(EventType, JSONValue)] {
        let size = text.utf8.count
        guard size > StepText.inlineLimit else { return try chunkDrafts(id, text) }
        let blob = try await putBlob(Data(text.utf8))
        let (preview, _) = StepText.preview(text)
        open[id]?.chunks = 1
        open[id]?.bytes = size
        let output = StepOutput(
            step: id, seq: 1, text: preview, blob: blob, bytes: size,
            truncated: blob == nil ? true : nil)
        return [(StepEventType.output, try Payload.encode(output))]
    }
}
