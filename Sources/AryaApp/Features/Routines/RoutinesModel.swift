import Foundation

/// One entry in a routine's history.
struct RoutineEvent: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case proposed, promoted, retired
    }

    var kind: Kind
    var version: String
    var at: Date
    var actor: FeatureActor
    var summary: String
    var reason: String
    var run: String?
}

/// A named routine: its live version, every version it has had, and its history.
struct RoutineItem: Identifiable, Hashable, Sendable {
    var name: String
    var steward: String?
    var live: String?
    /// Versions in the order they were first proposed.
    var versions: [String]
    var history: [RoutineEvent]

    var id: String { "\(steward ?? "")/\(name)" }

    /// The default comparison: the newest version against the live one, or the newest two.
    var defaultComparison: (old: String, new: String)? {
        guard let newest = versions.last else { return nil }
        if let live, live != newest { return (live, newest) }
        guard versions.count >= 2 else { return nil }
        return (versions[versions.count - 2], newest)
    }
}

/// A steward's routines, sorted by name.
struct RoutineList: Hashable, Sendable {
    var routines: [RoutineItem]

    /// Reads AryaMemory's `routine.proposed`, `routine.promoted`, and `routine.retired`.
    static func build(events: [FeatureEvent], steward: String? = nil) -> RoutineList {
        var items: [String: RoutineItem] = [:]
        for event in events where event.type.hasPrefix("routine.") {
            guard steward == nil || event.steward == steward,
                let kind = RoutineEvent.Kind(rawValue: String(event.type.dropFirst(8))),
                let name = event.payload["name"]?.string,
                let version = event.payload["version"]?.string
            else { continue }
            let key = "\(event.steward ?? "")/\(name)"
            var item =
                items[key]
                ?? RoutineItem(name: name, steward: event.steward, versions: [], history: [])
            if !item.versions.contains(version) { item.versions.append(version) }
            switch kind {
            case .promoted: item.live = version
            case .retired where item.live == version: item.live = nil
            default: break
            }
            item.history.append(
                RoutineEvent(
                    kind: kind, version: version, at: event.at, actor: event.actor,
                    summary: event.payload["summary"]?.string ?? "",
                    reason: event.payload["reason"]?.string ?? "",
                    run: event.payload["run"]?.string ?? event.run))
            items[key] = item
        }
        return RoutineList(routines: items.values.sorted { $0.id < $1.id })
    }
}

/// Text for the routines view, kept apart from layout so it can be tested.
enum RoutinesText {
    /// "sha256:1a2b3c" shortened for tables: "1a2b3c".
    static func shortVersion(_ version: String) -> String {
        let hex = version.split(separator: ":").last.map(String.init) ?? version
        return String(hex.prefix(12))
    }

    /// "live 1a2b3c", or "not live".
    static func live(_ item: RoutineItem) -> String {
        item.live.map { "live \(shortVersion($0))" } ?? "not live"
    }

    /// "Proposed 4d5e6f by st_triage: Label duplicates directly".
    static func history(_ event: RoutineEvent) -> String {
        let verb = event.kind.rawValue.prefix(1).uppercased() + event.kind.rawValue.dropFirst()
        var text = "\(verb) \(shortVersion(event.version)) by \(HumanText.actor(event.actor))"
        let detail = event.summary.isEmpty ? event.reason : event.summary
        if !detail.isEmpty { text += ": \(detail)" }
        return text
    }
}
