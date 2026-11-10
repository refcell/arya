import AryaCore
import Foundation

// Work events: what a run's tools are doing while they do it (docs/PROTOCOL.md, "Work
// events"). They travel as ordinary `run/event` kinds and decode as `.other`, so hosts that
// predate them keep working; these views read them typed.

extension RunEvent {
    /// A chunk of a tool's output while it runs: kind `tool_output`.
    public struct OutputChunk: Sendable, Hashable {
        /// The `tool_call` id the output belongs to.
        public var id: String
        /// `stdout` or `stderr`.
        public var stream: String
        /// The text, newlines included; chunks concatenate in `seq` order.
        public var text: String

        public init(id: String, stream: String = "stdout", text: String) {
            self.id = id
            self.stream = stream
            self.text = text
        }
    }

    /// An edit as a unified diff: kind `diff`.
    public struct FileDiff: Sendable, Hashable {
        /// What changed, such as `routines/flag-duplicate-charges.sh`.
        public var path: String
        /// A unified diff (`---`/`+++` header, then `@@` hunks).
        public var patch: String
        /// The `tool_call` id that made the edit, when one did.
        public var id: String?

        public init(path: String, patch: String, id: String? = nil) {
            self.path = path
            self.patch = patch
            self.id = id
        }

        /// Lines added and removed, counted from the hunks.
        public var counts: (added: Int, removed: Int) {
            var added = 0
            var removed = 0
            for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
                if line.hasPrefix("+") { added += 1 } else if line.hasPrefix("-") { removed += 1 }
            }
            return (added, removed)
        }
    }

    /// How far a run has got: kind `progress`.
    public struct Progress: Sendable, Hashable {
        public var done: Int
        public var total: Int
        public var label: String?

        public init(done: Int, total: Int, label: String? = nil) {
            self.done = done
            self.total = total
            self.label = label
        }
    }

    public static func output(_ chunk: OutputChunk) -> RunEvent {
        RunEvent(
            .other(
                kind: "tool_output",
                fields: chunk.stream == "stdout"
                    ? ["id": .string(chunk.id), "text": .string(chunk.text)]
                    : [
                        "id": .string(chunk.id), "stream": .string(chunk.stream),
                        "text": .string(chunk.text),
                    ]))
    }

    public static func diff(_ diff: FileDiff) -> RunEvent {
        var fields: [String: JSONValue] = [
            "path": .string(diff.path), "patch": .string(diff.patch),
        ]
        if let id = diff.id { fields["id"] = .string(id) }
        return RunEvent(.other(kind: "diff", fields: fields))
    }

    public static func progress(_ progress: Progress) -> RunEvent {
        var fields: [String: JSONValue] = [
            "done": .int(Int64(progress.done)), "total": .int(Int64(progress.total)),
        ]
        if let label = progress.label { fields["label"] = .string(label) }
        return RunEvent(.other(kind: "progress", fields: fields))
    }

    /// The event as an output chunk, when it is one.
    public var outputChunk: OutputChunk? {
        guard case .other("tool_output", let fields) = body, let id = fields["id"]?.stringValue,
            let text = fields["text"]?.stringValue
        else { return nil }
        return OutputChunk(id: id, stream: fields["stream"]?.stringValue ?? "stdout", text: text)
    }

    /// The event as a diff, when it is one.
    public var fileDiff: FileDiff? {
        guard case .other("diff", let fields) = body, let path = fields["path"]?.stringValue,
            let patch = fields["patch"]?.stringValue
        else { return nil }
        return FileDiff(path: path, patch: patch, id: fields["id"]?.stringValue)
    }

    /// The event as progress, when it is one.
    public var progress: Progress? {
        guard case .other("progress", let fields) = body,
            let done = fields["done"]?.intValue, let total = fields["total"]?.intValue
        else { return nil }
        return Progress(done: Int(done), total: Int(total), label: fields["label"]?.stringValue)
    }
}
