import Foundation

/// A proposal's gate result, mirroring `GateCheckVerdict`.
struct GateResult: Hashable, Sendable {
    var passed: Bool
    var baselineMean: Double?
    var candidateMean: Double
    var regressions: [String]
    var reason: String
}

/// A proposed change to a charter or routine, its gate result, and what became of it.
struct ProposalItem: Identifiable, Hashable, Sendable {
    enum State: Hashable, Sendable {
        case open
        case accepted(by: FeatureActor, overridden: Bool)
        case rejected(by: FeatureActor, reason: String)
    }

    var id: String
    var kind: String
    var title: String
    var reason: String
    var candidateVersion: Int?
    var steward: String?
    var run: String?
    var author: FeatureActor
    var createdAt: Date
    var gate: GateResult?
    var state: State = .open

    var isOpen: Bool { state == .open }
    /// Accept needs a passing gate.
    var canAccept: Bool { isOpen && gate?.passed == true }
    /// Override is only for a failed gate, and is recorded with the person as actor.
    var canOverride: Bool { isOpen && gate?.passed == false }
}

/// The Changes tab: open proposals newest first, then closed ones newest first.
struct ChangeList: Hashable, Sendable {
    var open: [ProposalItem]
    var closed: [ProposalItem]

    static func build(events: [FeatureEvent], steward: String? = nil) -> ChangeList {
        var items: [String: ProposalItem] = [:]
        var order: [String] = []
        var overridden: Set<String> = []
        for event in events where steward == nil || event.steward == steward {
            let p = event.payload
            // The ledger names the proposal `proposal`; older fixtures use `id`.
            if event.type == "proposal.created", let id = p["proposal"]?.string ?? p["id"]?.string {
                items[id] = created(id, event)
                order.append(id)
                continue
            }
            guard let id = p["proposal"]?.string, items[id] != nil else { continue }
            switch event.type {
            case "proposal.gated": items[id]?.gate = gate(p)
            case "proposal.overridden": overridden.insert(id)
            case "proposal.accepted":
                items[id]?.state = .accepted(by: event.actor, overridden: overridden.contains(id))
            case "proposal.rejected":
                items[id]?.state = .rejected(by: event.actor, reason: p["reason"]?.string ?? "")
            default: continue
            }
        }
        let all = order.reversed().compactMap { items[$0] }
        return ChangeList(open: all.filter(\.isOpen), closed: all.filter { !$0.isOpen })
    }

    private static func created(_ id: String, _ event: FeatureEvent) -> ProposalItem {
        let p = event.payload
        // The facade stores the title as the first line of `reason`.
        let firstLine = p["reason"]?.string?.split(separator: "\n").first.map(String.init)
        return ProposalItem(
            id: id, kind: p["kind"]?.string ?? "charter",
            title: p["title"]?.string ?? firstLine ?? id,
            reason: p["reason"]?.string ?? "",
            candidateVersion: p["candidateVersion"]?.number.map { Int($0) },
            steward: event.steward, run: event.run, author: event.actor, createdAt: event.at)
    }

    private static func gate(_ payload: FeatureJSON) -> GateResult {
        // `proposal.gated` nests the result under `verdict`; older fixtures put it at the top.
        let p = payload["verdict"] ?? payload
        return GateResult(
            passed: p["passed"]?.bool ?? false, baselineMean: p["baselineMean"]?.number,
            candidateMean: p["candidateMean"]?.number ?? 0,
            regressions: p["regressions"]?.strings ?? [],
            reason: p["reason"]?.string ?? "")
    }
}

/// Text for the Changes tab, kept apart from layout so it can be tested.
enum ChangesText {
    /// "charter v2 · from local", "routine · from run_0001".
    static func meta(_ item: ProposalItem) -> String {
        let version = item.candidateVersion.map { " v\($0)" } ?? ""
        let from = item.run ?? item.author.id
        return "\(item.kind)\(version) · from \(from)"
    }

    /// "Score 0.92 against a baseline of 0.90", or a waiting note.
    static func gate(_ gate: GateResult?) -> String {
        guard let gate else { return "Rehearsing against the casebook." }
        let candidate = score(gate.candidateMean)
        guard let baseline = gate.baselineMean else {
            return "Score \(candidate); no baseline yet."
        }
        return "Score \(candidate) against a baseline of \(score(baseline))."
    }

    /// "Regressed: case-0003, case-0007", or nil.
    static func regressions(_ gate: GateResult?) -> String? {
        guard let gate, !gate.regressions.isEmpty else { return nil }
        return "Regressed: " + gate.regressions.joined(separator: ", ")
    }

    /// The closed state: "Accepted by you", "Accepted by you over a failed gate",
    /// "Rejected by you: too broad".
    static func state(_ state: ProposalItem.State) -> String {
        switch state {
        case .open: return "Open"
        case .accepted(let by, let overridden):
            return "Accepted by \(HumanText.actor(by))" + (overridden ? " over a failed gate" : "")
        case .rejected(let by, let reason):
            return "Rejected by \(HumanText.actor(by))" + (reason.isEmpty ? "" : ": \(reason)")
        }
    }

    static func score(_ value: Double) -> String { String(format: "%.2f", value) }
}
