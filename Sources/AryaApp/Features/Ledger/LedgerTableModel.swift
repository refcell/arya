import Foundation

/// The ledger table's filters. A nil field matches everything.
struct LedgerFilter: Hashable, Sendable {
    var steward: String?
    var run: String?
    /// An exact type (`run.decision`) or a namespace ending in a dot (`approval.`).
    var type: String?
    /// An actor as `kind:id` (`human:local`).
    var actor: String?
    /// Free text matched against the type, run and its title, actor, and payload.
    var query = ""

    static let all = LedgerFilter()

    func matches(_ event: FeatureEvent) -> Bool {
        if let steward, event.steward != steward { return false }
        if let run, event.run != run { return false }
        if let type {
            if type.hasSuffix(".") {
                if !event.type.hasPrefix(type) { return false }
            } else if event.type != type {
                return false
            }
        }
        if let actor, LedgerTable.actorLabel(event.actor) != actor { return false }
        return true
    }

    /// Whether the event contains the search text, ignoring case.
    func matchesQuery(_ event: FeatureEvent, title: String?) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        let fields = [
            event.type, event.run ?? "", title ?? "", LedgerTable.actorLabel(event.actor),
            event.steward ?? "", event.payload.compactText,
        ]
        return fields.contains { $0.lowercased().contains(needle) }
    }

    /// Whether any filter is set.
    var isActive: Bool { self != .all }
}

/// The ledger as a table: the rows that pass the filter, newest first, and the values each
/// filter can take.
struct LedgerTable: Hashable, Sendable {
    var rows: [FeatureEvent]
    var total: Int
    var stewards: [String]
    var runs: [String]
    var namespaces: [String]
    var actors: [String]
    /// Each run's short title: its summary, else the first line of its input.
    var runTitles: [String: String] = [:]

    static func build(events: [FeatureEvent], filter: LedgerFilter) -> LedgerTable {
        let scoped = events.filter { filter.steward == nil || $0.steward == filter.steward }
        let titles = runTitles(events)
        return LedgerTable(
            rows: events.filter {
                filter.matches($0) && filter.matchesQuery($0, title: $0.run.flatMap { titles[$0] })
            }.reversed(),
            total: events.count,
            stewards: distinct(events.compactMap(\.steward)),
            runs: distinct(scoped.compactMap(\.run)),
            namespaces: distinct(events.map(namespace)),
            actors: distinct(events.map { actorLabel($0.actor) }),
            runTitles: titles)
    }

    /// Run titles from `run.finished` summaries, falling back to the `run.started` input.
    static func runTitles(_ events: [FeatureEvent]) -> [String: String] {
        var titles: [String: String] = [:]
        for event in events {
            guard let run = event.run else { continue }
            switch event.type {
            case "run.started":
                let input = event.payload["input"]?["text"]?.string ?? ""
                if let line = input.split(separator: "\n").first, titles[run] == nil {
                    titles[run] = String(line)
                }
            case "run.finished":
                if let summary = event.payload["summary"]?.string, !summary.isEmpty {
                    titles[run] = summary
                }
            default: continue
            }
        }
        return titles
    }

    /// The longest type in the rows, so the mono type column lines up.
    var typeWidth: Int { rows.map(\.type.count).max() ?? 0 }
    /// The most digits in a row's seq.
    var seqWidth: Int { rows.map { String($0.seq).count }.max() ?? 1 }

    /// `kind:id`, for example `human:local`.
    static func actorLabel(_ actor: FeatureActor) -> String { "\(actor.kind.rawValue):\(actor.id)" }

    /// The type's namespace with its dot: `run.` for `run.tool.call`.
    static func namespace(_ event: FeatureEvent) -> String {
        guard let dot = event.type.firstIndex(of: ".") else { return event.type }
        return String(event.type[...dot])
    }

    private static func distinct(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }
}

/// Text for the ledger view, kept apart from layout so it can be tested.
enum LedgerText {
    /// A hash or prev for the inspector; an empty prev marks the first event.
    static func chainValue(_ value: String, label: String) -> String {
        guard value.isEmpty else { return value }
        return label == "Prev" ? "none (first event)" : "—"
    }

    /// "Showing 3 of 42 events".
    static func count(_ table: LedgerTable) -> String {
        if table.rows.count == table.total { return "\(table.total) events" }
        return "Showing \(table.rows.count) of \(table.total) events"
    }

    /// `text` padded with spaces to `width` characters, leading or trailing, for mono columns.
    static func pad(_ text: String, _ width: Int, leading: Bool = false) -> String {
        let fill = String(repeating: " ", count: max(0, width - text.count))
        return leading ? fill + text : text + fill
    }

    /// The run column: its title, else a short id, else a dash for events outside a run.
    static func runLabel(_ event: FeatureEvent, titles: [String: String]) -> String {
        guard let run = event.run else { return "—" }
        return titles[run] ?? "run …" + run.suffix(6)
    }

    /// The verify result as one sentence with the next step on failure.
    static func verify(_ result: FeatureVerifyResult) -> String {
        switch result {
        case .intact(let events):
            return "The ledger is intact: \(events) events, every hash and sequence checked."
        case .broken(let seq, let reason):
            return "The chain breaks at event \(seq): \(reason). "
                + "The ledger is read-only until you review it."
        }
    }

    /// The fields of an event's detail pane, in display order.
    static func detail(_ event: FeatureEvent) -> [(label: String, value: String)] {
        [
            ("seq", String(event.seq)), ("id", event.id), ("at", FeatureTime.absolute(event.at)),
            ("type", event.type), ("steward", event.steward ?? "—"), ("run", event.run ?? "—"),
            ("actor", LedgerTable.actorLabel(event.actor)),
            ("hash", event.hash.isEmpty ? "—" : event.hash),
        ]
    }
}

extension LedgerFilter {
    /// Whether a menu filter (not the search text) is set.
    var isFiltered: Bool { steward != nil || run != nil || type != nil || actor != nil }
}

extension FeatureVerifyResult {
    var isIntact: Bool {
        if case .intact = self { return true }
        return false
    }
}

extension LedgerText {
    /// "✓ chain verified · 829 events" or "✗ chain broken at 412 · 829 events".
    static func verifyStatus(_ result: FeatureVerifyResult, count: String) -> String {
        switch result {
        case .intact: "✓ chain verified · \(count)"
        case .broken(let seq, _): "✗ chain broken at \(seq) · \(count)"
        }
    }
}

extension LedgerText {
    /// "Step 3 of 18 · Labeled MSG-201 as billing", else the run title, else a short id.
    static func step(_ step: FeatureEventDetail.Step?, title: String?, run: String) -> String {
        let recorded = step.map(\.title).flatMap { $0.isEmpty ? nil : $0 }
        let name = recorded ?? title ?? "run …" + run.suffix(6)
        guard let step else { return name }
        return "Step \(step.index) of \(step.count) · \(name)"
    }
}

/// One line of the ledger list: an event, or a collapsed run of consecutive adapter events.
enum LedgerLine: Identifiable, Hashable, Sendable {
    case event(FeatureEvent)
    /// Consecutive `run.adapter.event` rows of one run, newest first; `id` is the newest seq.
    case adapterRun(id: Int, events: [FeatureEvent])

    var id: String {
        switch self {
        case .event(let event): event.id
        case .adapterRun(let id, _): "adapter-\(id)"
        }
    }
}

extension LedgerTable {
    static let collapsedType = "run.adapter.event"

    /// The rows as lines, folding each run of two or more consecutive adapter events of one
    /// run into one line unless its id is in `expanded`.
    func lines(expanded: Set<String>) -> [LedgerLine] {
        var lines: [LedgerLine] = []
        var pending: [FeatureEvent] = []
        func flush() {
            let group = LedgerLine.adapterRun(id: pending.first?.seq ?? 0, events: pending)
            if pending.count >= 2, !expanded.contains(group.id) {
                lines.append(group)
            } else {
                lines += pending.map(LedgerLine.event)
            }
            pending = []
        }
        for event in rows {
            if event.type == Self.collapsedType, pending.isEmpty || pending.last?.run == event.run {
                pending.append(event)
                continue
            }
            if !pending.isEmpty { flush() }
            if event.type == Self.collapsedType {
                pending.append(event)
            } else {
                lines.append(.event(event))
            }
        }
        if !pending.isEmpty { flush() }
        return lines
    }
}
