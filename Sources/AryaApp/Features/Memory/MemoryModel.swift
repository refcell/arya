import Foundation

/// A memory note with its provenance and whether it is still shown to runs.
struct MemoryItem: Identifiable, Hashable, Sendable {
    struct Retraction: Hashable, Sendable {
        var by: FeatureActor
        var reason: String
        var at: Date
    }

    var id: String
    var text: String
    var tags: [String]
    var steward: String?
    var run: String?
    var event: String?
    var caseID: String?
    var author: FeatureActor
    var addedAt: Date
    var retraction: Retraction?

    var isLive: Bool { retraction == nil }
}

/// A steward's memory: live notes newest first, then retracted ones.
struct MemoryList: Hashable, Sendable {
    var live: [MemoryItem]
    var retracted: [MemoryItem]

    /// `memory.added` is `{v, note: MemoryNote}`; `memory.retracted` is `{v, note: id, reason?}`.
    static func build(events: [FeatureEvent], steward: String? = nil) -> MemoryList {
        var items: [String: MemoryItem] = [:]
        var order: [String] = []
        for event in events where steward == nil || event.steward == steward {
            switch event.type {
            case "memory.added":
                guard let note = event.payload["note"], let id = note["id"]?.string else {
                    continue
                }
                items[id] = item(id, note, event)
                order.append(id)
            case "memory.retracted":
                guard let id = event.payload["note"]?.string, items[id] != nil else { continue }
                items[id]?.retraction = MemoryItem.Retraction(
                    by: event.actor, reason: event.payload["reason"]?.string ?? "", at: event.at)
            default: continue
            }
        }
        let all = order.reversed().compactMap { items[$0] }
        return MemoryList(live: all.filter(\.isLive), retracted: all.filter { !$0.isLive })
    }

    private static func item(_ id: String, _ note: FeatureJSON, _ event: FeatureEvent) -> MemoryItem
    {
        let provenance = note["provenance"] ?? [:]
        let author = provenance["author"].flatMap(actor) ?? event.actor
        return MemoryItem(
            id: id, text: note["text"]?.string ?? "", tags: note["tags"]?.strings ?? [],
            steward: event.steward, run: provenance["run"]?.string,
            event: provenance["event"]?.string, caseID: provenance["case"]?.string,
            author: author, addedAt: event.at)
    }

    private static func actor(_ json: FeatureJSON) -> FeatureActor? {
        guard let raw = json["kind"]?.string, let kind = FeatureActor.Kind(rawValue: raw),
            let id = json["id"]?.string
        else { return nil }
        return FeatureActor(kind: kind, id: id)
    }
}

/// Text for the memory view, kept apart from layout so it can be tested.
enum MemoryText {
    /// "by st_triage · from run_0001 (ev_6) · 2m ago", "by local · from case case-0007".
    static func provenance(_ item: MemoryItem, now: Date) -> String {
        var parts = ["by \(item.author.id)"]
        if let run = item.run {
            parts.append("from \(run)" + (item.event.map { " (\($0))" } ?? ""))
        }
        if let caseID = item.caseID { parts.append("from case \(caseID)") }
        parts.append(FeatureTime.relative(item.addedAt, now: now))
        return parts.joined(separator: " · ")
    }

    /// "Retracted by local: outdated".
    static func retraction(_ retraction: MemoryItem.Retraction) -> String {
        "Retracted by \(retraction.by.id)"
            + (retraction.reason.isEmpty ? "" : ": \(retraction.reason)")
    }
}
