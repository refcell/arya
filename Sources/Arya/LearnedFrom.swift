import AryaCore
import AryaEval
import AryaMemory
import Foundation

/// What stewards learned from one person, across every steward: the memory notes they
/// authored (inbox corrections, case corrections, preferences), the cases they corrected, and
/// the cases they reviewed. For the person inspector's LEARNED FROM list.
public struct LearnedFromSummary: Sendable, Hashable, Codable {
    public struct Item: Sendable, Hashable, Codable, Identifiable {
        public var id: String
        /// `note`, `correction` (a case corrected), or `review` (a case agreed or skipped).
        public var kind: String
        public var text: String
        public var steward: String?
        public var at: Date
        /// `correction`, `case correction`, `preference`, or `note` for notes; `agreed` or
        /// `skipped` for reviews; `corrected` for corrections.
        public var source: String
        /// False for retracted notes.
        public var live: Bool
        public var caseID: String?
    }

    public var person: String
    /// Newest first; retracted notes last.
    public var items: [Item]
    /// Live notes the person taught.
    public var taught: Int
    public var corrections: Int
    public var reviews: Int
    /// Stewards that learned from them, by id.
    public var stewards: [String]
    /// One line, shown verbatim: `Taught 3 notes to 2 stewards; corrected 1 case; reviewed 4.`
    public var summary: String
}

extension Workspace {
    /// Everything stewards learned from `person` (a person id such as `person:alex`, or
    /// `local`), from the cached memory projection and ledger.
    public func learnedFrom(person: String) async throws -> LearnedFromSummary {
        let state = try facadeState()
        let bare = person.hasPrefix("person:") ? String(person.dropFirst(7)) : person
        func matches(_ id: String) -> Bool { id == person || id == bare || id == "person:" + bare }
        var live: [LearnedFromSummary.Item] = []
        var retracted: [LearnedFromSummary.Item] = []
        for steward in state.memory.stewards {
            for (entry, gone) in state.memory.allNotes(steward: steward) {
                let note = entry.note
                guard note.provenance.author.kind == .human, matches(note.provenance.author.id)
                else { continue }
                let source =
                    note.provenance.caseID != nil
                    ? "case correction"
                    : note.tags.contains("correction")
                        ? "correction" : note.tags.contains("preference") ? "preference" : "note"
                let item = LearnedFromSummary.Item(
                    id: note.id.rawValue, kind: "note", text: note.text,
                    steward: steward.rawValue, at: state.date(seq: entry.seq) ?? .distantPast,
                    source: source, live: !gone, caseID: note.provenance.caseID?.rawValue)
                if gone { retracted.append(item) } else { live.append(item) }
            }
        }
        for event in state.runtime
        where event.draft.actor.kind != "steward" && matches(event.draft.actor.id) {
            let caseID = event.payload["case"]?.stringValue
            switch event.type {
            case EvalEventType.caseCorrected:
                live.append(
                    .init(
                        id: "seq-\(event.seq)", kind: "correction",
                        text: event.payload["text"]?.stringValue ?? "",
                        steward: event.draft.steward?.rawValue, at: event.at.date,
                        source: "corrected", live: true, caseID: caseID))
            case ReviewEventType.reviewed:
                let verdict = event.payload["verdict"]?.stringValue ?? "reviewed"
                live.append(
                    .init(
                        id: "seq-\(event.seq)", kind: "review",
                        text: "\(verdict.capitalized) \(caseID ?? "a case")",
                        steward: event.draft.steward?.rawValue, at: event.at.date,
                        source: verdict, live: true, caseID: caseID))
            default:
                continue
            }
        }
        let items =
            live.sorted { $0.at > $1.at } + retracted.sorted { $0.at > $1.at }
        let taught = live.filter { $0.kind == "note" }.count
        let corrections = items.filter { $0.kind == "correction" }.count
        let reviews = items.filter { $0.kind == "review" }.count
        let stewards = Array(Set(items.compactMap(\.steward))).sorted()
        var parts: [String] = []
        if taught > 0 {
            parts.append(
                "Taught \(Self.count(taught, "note", "notes")) to "
                    + Self.count(
                        Set(live.filter { $0.kind == "note" }.compactMap(\.steward))
                            .count, "steward", "stewards"))
        }
        if corrections > 0 { parts.append("corrected \(Self.count(corrections, "case", "cases"))") }
        if reviews > 0 { parts.append("reviewed \(reviews)") }
        let summary =
            parts.isEmpty
            ? "Nothing learned from \(person) yet."
            : parts.joined(separator: "; ").prefix(1).uppercased()
                + parts.joined(separator: "; ").dropFirst() + "."
        return LearnedFromSummary(
            person: person, items: items, taught: taught, corrections: corrections,
            reviews: reviews, stewards: stewards, summary: summary)
    }
}
