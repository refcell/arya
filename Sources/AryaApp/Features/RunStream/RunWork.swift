import Foundation

/// The work pane's four tabs.
enum WorkTab: Int, CaseIterable, Hashable, Sendable {
    case tools = 1
    case diff
    case log
    case output

    var title: String {
        switch self {
        case .tools: "Tools"
        case .diff: "Diff"
        case .log: "Log"
        case .output: "Output"
        }
    }
}

/// One tool call, action, or delegation as a block: a header line and its output in mono.
struct WorkBlock: Identifiable, Hashable, Sendable {
    struct Section: Hashable, Sendable {
        var label: String
        var text: String
    }

    /// The step id, shared with the conversation line, so selecting either finds the other.
    var id: String
    var mark: WorkMark
    var title: String
    var target: String?
    /// "via inbox · 1 ms"; empty when nothing is known.
    var meta: String
    var sections: [Section]
}

/// A change the run made or proposed, as unified diff text.
struct WorkDiff: Identifiable, Hashable, Sendable {
    /// A routine whose text loads from the workspace: `version` against `previous`.
    struct Routine: Hashable, Sendable {
        var steward: String
        var name: String
        var version: String
        var previous: String?
    }

    var id: String
    var title: String
    var text: String
    var routine: Routine? = nil

    var added: Int { counts.added }
    var removed: Int { counts.removed }

    private var counts: (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for line in text.split(separator: "\n") {
            if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            if line.hasPrefix("+") { added += 1 }
            if line.hasPrefix("-") { removed += 1 }
        }
        return (added, removed)
    }

    /// "+3 −1".
    var countText: String { "+\(added) −\(removed)" }
}

/// One mono line in the Log or Output tab.
struct WorkLine: Identifiable, Hashable, Sendable {
    enum Tone: Hashable, Sendable { case plain, sent, received, failed }

    var id: String
    var time: String
    var tag: String
    var text: String
    var tone: Tone = .plain
    /// Streamed output: when long, its last lines show, as in a terminal.
    var tails = false
}

/// What the work pane shows for one run, projected from its stream and ledger events.
struct RunWork: Hashable, Sendable {
    var blocks: [WorkBlock]
    var diffs: [WorkDiff]
    var log: [WorkLine]
    var output: [WorkLine]

    func count(_ tab: WorkTab) -> Int {
        switch tab {
        case .tools: blocks.count
        case .diff: diffs.count
        case .log: log.count
        case .output: output.count
        }
    }

    /// The step ids that have a block, in order; j/k and selection move through these.
    static func isWork(_ kind: StreamStep.Kind) -> Bool {
        switch kind {
        case .toolCall, .action, .delegated: true
        default: false
        }
    }

    static func build(
        stream: RunStream, events: [FeatureEvent], timeZone: TimeZone = .current
    ) -> RunWork {
        let mine = events.filter { $0.run == stream.run }
        var diffs = stream.steps.compactMap(actionDiff)
        diffs += routineDiffs(mine, all: events)
        // A harness edit of a routine's file shows once, as the routine's version diff.
        let routines = Set(diffs.compactMap { $0.routine?.name })
        diffs += mine.compactMap(adapterDiff).filter { diff in
            let file = diff.title.split(separator: "/").last.map(String.init) ?? diff.title
            let stem = file.split(separator: ".").first.map(String.init) ?? file
            return !(diff.title.contains("routines/") && routines.contains(stem))
        }
        // In the order the run made them.
        let order = Dictionary(mine.map { ($0.id, $0.seq) }, uniquingKeysWith: { a, _ in a })
        diffs.sort { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
        let log = mine.filter { $0.type != "run.adapter.event" }.map {
            logLine($0, timeZone: timeZone)
        }
        let output = outputLines(mine, timeZone: timeZone)
        return RunWork(
            blocks: stream.steps.compactMap(block), diffs: diffs, log: log, output: output)
    }

    // MARK: blocks

    static func block(_ step: StreamStep) -> WorkBlock? {
        let mark = StreamStepText.mark(step.kind)
        switch step.kind {
        case .toolCall(let call):
            var sections = [WorkBlock.Section(label: "input", text: call.input.prettyText)]
            if let output = call.output {
                sections.append(
                    .init(label: call.isError ? "error" : "output", text: output.prettyText))
            }
            return WorkBlock(
                id: step.id, mark: mark, title: call.tool,
                target: RunThreadText.argument(call.input), meta: RunThreadText.toolMeta(call),
                sections: sections)
        case .action(let action):
            var meta: [String] = []
            if let binding = action.binding { meta.append("via \(binding)") }
            if action.refusal != nil, let note = RunThreadText.actionNote(action) {
                meta.append(note)
            } else {
                meta.append(ActionWords.outcome(action))
            }
            if let check = action.check { meta.append(check.text(since: step.at)) }
            var sections: [WorkBlock.Section] = []
            if action.params != [:], action.params != .null {
                sections.append(.init(label: "params", text: action.params.prettyText))
            }
            if !action.rationale.isEmpty {
                sections.append(.init(label: "why", text: action.rationale))
            }
            switch action.outcome {
            case .executed(let output) where !output.isEmpty:
                sections.append(.init(label: "result", text: output))
            case .failed(let error): sections.append(.init(label: "error", text: error))
            case .denied(_, let reason) where !reason.isEmpty:
                sections.append(.init(label: "denied", text: reason))
            default: break
            }
            return WorkBlock(
                id: step.id, mark: mark, title: action.kind, target: action.target,
                meta: meta.joined(separator: " · "), sections: sections)
        case .delegated(let delegation):
            let lines = delegation.childSteps.map {
                "\(StreamStepText.clock($0.at))  \(StreamStepText.title($0.kind))"
            }
            var sections: [WorkBlock.Section] = []
            if !lines.isEmpty {
                sections.append(.init(label: "child run", text: lines.joined(separator: "\n")))
            }
            if let refusal = delegation.refused {
                sections.append(.init(label: "refused", text: refusal))
            }
            return WorkBlock(
                id: step.id, mark: mark, title: "crew", target: delegation.title,
                meta: delegation.seconds.map(FeatureTime.duration) ?? "", sections: sections)
        default:
            return nil
        }
    }

    static func outcomeWord(_ outcome: ActionOutcome) -> String {
        switch outcome {
        case .executed: "applied"
        case .proposed: "proposed"
        case .awaitingApproval: "waiting on you"
        case .approved: "approved"
        case .denied: "denied"
        case .rejected: "rejected"
        case .failed: "failed"
        }
    }

    // MARK: diffs

    /// What an action writes to its target, as added lines: "+label: shipping", or the text of
    /// a reply line by line.
    static func actionDiff(_ step: StreamStep) -> WorkDiff? {
        guard case .action(let action) = step.kind else { return nil }
        var added: [String] = []
        if case .object(let members) = action.params {
            for key in members.keys.sorted() {
                guard let value = members[key] else { continue }
                switch value {
                case .string(let text) where text.contains("\n") || text.count > 60:
                    added.append("\(key):")
                    added += text.split(separator: "\n", omittingEmptySubsequences: false)
                        .map { "  \($0)" }
                case .object, .array:
                    added += value.prettyText.split(separator: "\n").map { "\(key) \($0)" }
                case .string(let text):
                    // The value itself when the key names the action: "+bug" for a label.
                    let value = EntityName.humanize(text)
                    added.append(key == action.kind ? value : "\(key): \(value)")
                default:
                    added.append(
                        key == action.kind ? value.compactText : "\(key): \(value.compactText)")
                }
            }
        }
        if added.isEmpty { added = [action.kind] }
        let target = EntityName.plain(action.target)
        let text =
            (["--- \(target)", "+++ \(target)", "@@ \(action.kind) @@"]
            + added.map { "+\($0)" }).joined(separator: "\n")
        return WorkDiff(id: step.id, title: "\(action.kind) \(target)", text: text)
    }

    /// An edit the harness reported (`diff` event: `path`, `patch`), as it reported it.
    static func adapterDiff(_ event: FeatureEvent) -> WorkDiff? {
        guard event.type == "run.adapter.event",
            let inner = event.payload["message"]?["params"]?["event"],
            inner["kind"]?.string == "diff", let patch = inner["patch"]?.string
        else { return nil }
        let path = inner["path"]?.string ?? "file"
        let text = patch.hasPrefix("---") ? patch : "--- \(path)\n+++ \(path)\n" + patch
        return WorkDiff(id: event.id, title: path, text: text)
    }

    /// Routines the run proposed; their text loads from the workspace.
    static func routineDiffs(_ mine: [FeatureEvent], all: [FeatureEvent]) -> [WorkDiff] {
        mine.filter { $0.type == "routine.proposed" }.compactMap { event in
            guard let name = event.payload["name"]?.string,
                let version = event.payload["version"]?.string, let steward = event.steward
            else { return nil }
            let previous = all.last {
                $0.seq < event.seq && $0.type == "routine.proposed"
                    && $0.payload["name"]?.string == name
            }?.payload["version"]?.string
            return WorkDiff(
                id: event.id, title: "routine \(name)", text: "",
                routine: .init(steward: steward, name: name, version: version, previous: previous))
        }
    }

    // MARK: log and output

    static func logLine(_ event: FeatureEvent, timeZone: TimeZone) -> WorkLine {
        var parts: [String] = []
        if case .object(let members) = event.payload {
            for key in members.keys.sorted() where key != "v" {
                switch members[key] {
                case .string(let text)? where text.count <= 48 && !text.contains("\n"):
                    parts.append("\(key)=\(text)")
                case .number?, .bool?:
                    parts.append("\(key)=\(members[key]?.compactText ?? "")")
                default: continue
                }
            }
        }
        let failed = event.type.hasSuffix(".failed") || event.type.hasSuffix("error")
        return WorkLine(
            id: event.id, time: StreamStepText.clock(event.at, timeZone: timeZone),
            tag: event.type, text: parts.joined(separator: " "), tone: failed ? .failed : .plain)
    }

    /// One JSON-RPC line: "→ initialize {"client":…}" or "← tool_call {…}".
    /// The adapter's wire lines, and each live step's output as one growing line per stretch
    /// of chunks (`run.step.output`). With step records, the adapter's own `tool_output`
    /// notifications are left out, since the same text arrives as chunks.
    static func outputLines(_ mine: [FeatureEvent], timeZone: TimeZone) -> [WorkLine] {
        let stepped = mine.contains { $0.type == "run.step.started" }
        var tools: [String: String] = [:]
        var lines: [WorkLine] = []
        var open: String?
        for event in mine {
            let p = event.payload
            switch event.type {
            case "run.adapter.event":
                let kind = p["message"]?["params"]?["event"]?["kind"]?.string
                if stepped, kind == "tool_output" { continue }
                lines.append(outputLine(event, timeZone: timeZone))
                open = nil
            case "run.step.started":
                if let step = p["step"]?.string { tools[step] = p["tool"]?.string }
            case "run.step.output":
                let step = p["step"]?.string ?? ""
                let text = p["text"]?.string ?? ""
                let stderr = p["stream"]?.string == "stderr"
                let key = step + (stderr ? ":err" : "")
                if key == open, var last = lines.popLast() {
                    last.text += text
                    lines.append(last)
                } else {
                    lines.append(
                        WorkLine(
                            id: event.id, time: StreamStepText.clock(event.at, timeZone: timeZone),
                            tag: "▸ " + (tools[step] ?? "output") + (stderr ? " stderr" : ""),
                            text: text, tone: stderr ? .failed : .plain, tails: true))
                    open = key
                }
            default: break
            }
        }
        return lines
    }

    static func outputLine(_ event: FeatureEvent, timeZone: TimeZone) -> WorkLine {
        let sent = ["sent", "out"].contains(event.payload["direction"]?.string ?? "")
        let message = event.payload["message"] ?? .null
        let method =
            message["method"]?.string
            ?? (message["error"] != nil ? "error" : message["result"] != nil ? "result" : "")
        let body = message["params"] ?? message["result"] ?? message["error"] ?? .null
        let tone: WorkLine.Tone = method == "error" ? .failed : sent ? .sent : .received
        // A notification carries an inner event: show its kind and its words, not the envelope.
        if method == "run/event", let inner = body["event"], let kind = inner["kind"]?.string {
            let words =
                inner["text"]?.string ?? inner["tool"]?.string ?? inner["message"]?.string
                ?? oneLine(inner, limit: 400)
            return WorkLine(
                id: event.id, time: StreamStepText.clock(event.at, timeZone: timeZone),
                tag: "← \(kind)", text: words, tone: kind == "error" ? .failed : .received)
        }
        return WorkLine(
            id: event.id, time: StreamStepText.clock(event.at, timeZone: timeZone),
            tag: (sent ? "→ " : "← ") + method, text: oneLine(body, limit: 400), tone: tone)
    }

    /// Compact JSON on one line, cut at `limit` characters.
    static func oneLine(_ value: FeatureJSON, limit: Int) -> String {
        if case .null = value { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8)
        else { return value.compactText }
        // String values keep their line breaks, so output reads as text, not escapes.
        let readable = text.replacingOccurrences(of: "\\n", with: "\n")
        return readable.count > limit ? String(readable.prefix(limit)) + "…" : readable
    }
}
