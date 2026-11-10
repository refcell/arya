import AryaCore
import AryaEval
import AryaRuntime
import Foundation

/// What a charter proposal does to the steward's safety, from the proposed charter against the
/// live one: whether it changes what the steward owns (the outcome sentence or the metric and
/// target), and what it removes or loosens (guardrails, sign-off, blocked actions, autonomy,
/// the adapter). Either one should keep Accept behind a confirm.
public struct ProposalImpact: Sendable, Hashable, Codable {
    /// What changed, as a set: `outcome`, `metric`, `guardrails`, `signoff`, `adapter`.
    public var kinds: [String] = []
    /// "“old outcome” → “new outcome”", "metric x ≥ 0.95 → x ≥ 0.9".
    public var owns: [String] = []
    /// Guardrails the proposal drops, verbatim.
    public var removedGuardrails: [String] = []
    /// "sign-off no longer required for refund", "adapter a → b".
    public var loosened: [String] = []

    public init() {}

    /// Everything removed or loosened, in plain words, for the approver.
    public var removed: [String] {
        removedGuardrails.map { "guardrail removed: “\($0)”" } + loosened
    }
    public var changesOwnership: Bool { !owns.isEmpty }
    public var loosens: Bool { !removedGuardrails.isEmpty || !loosened.isEmpty }
    /// Accept must not be the default: it stays quiet and asks for a confirm.
    public var needsConfirm: Bool { changesOwnership || loosens }

    /// "This changes what the steward owns: “…” → “…”."
    public var ownsSentence: String? {
        owns.isEmpty ? nil : "This changes what the steward owns: \(owns.joined(separator: "; "))."
    }

    /// "Removes 2 guardrails: “…”, “…”; sign-off no longer required for refund."
    public var loosensSentence: String? {
        var parts: [String] = []
        if !removedGuardrails.isEmpty {
            let count = removedGuardrails.count
            let noun = count == 1 ? "guardrail" : "guardrails"
            let list = removedGuardrails.map { "“\($0)”" }.joined(separator: ", ")
            parts.append("removes \(count) \(noun): \(list)")
        }
        parts += loosened
        guard let first = parts.first else { return nil }
        let text = ([first.prefix(1).uppercased() + first.dropFirst()] + parts.dropFirst())
            .joined(separator: "; ")
        return text + "."
    }

    /// The impact of making `proposed` live in place of `live`.
    public init(live: Charter, proposed: Charter) {
        var kinds: Set<String> = []
        if live.outcome != proposed.outcome {
            owns.append("“\(live.outcome)” → “\(proposed.outcome)”")
            kinds.insert("outcome")
        }
        if live.metric != proposed.metric {
            owns.append("metric \(Self.metric(live.metric)) → \(Self.metric(proposed.metric))")
            kinds.insert("metric")
        }
        let liveBounds = (live.guardrailMetrics ?? []).map(Self.metric)
        let proposedBounds = (proposed.guardrailMetrics ?? []).map(Self.metric)
        if liveBounds != proposedBounds {
            let before = liveBounds.isEmpty ? "none" : liveBounds.joined(separator: ", ")
            let after = proposedBounds.isEmpty ? "none" : proposedBounds.joined(separator: ", ")
            owns.append("guardrail metrics \(before) → \(after)")
            kinds.insert("metric")
        }
        let kept = Set(proposed.guardrails)
        removedGuardrails = live.guardrails.filter { !kept.contains($0) }
        if !removedGuardrails.isEmpty { kinds.insert("guardrails") }
        loosened = Self.signOff(live.policy, proposed.policy)
        if let autonomy = Self.autonomy(live.autonomy, proposed.autonomy) {
            loosened.append(autonomy)
        }
        if !loosened.isEmpty { kinds.insert("signoff") }
        if live.adapter != proposed.adapter {
            loosened.append("adapter \(live.adapter) → \(proposed.adapter)")
            kinds.insert("adapter")
        }
        self.kinds = kinds.sorted()
    }

    /// "routed_within_1h ≥ 0.95", or the name without a target.
    static func metric(_ metric: Metric) -> String {
        guard let target = metric.target else { return metric.name }
        let sign = metric.direction == .down ? "≤" : "≥"
        let value = target == target.rounded() ? String(Int(target)) : String(target)
        return "\(metric.name) \(sign) \(value)"
    }

    /// Actions whose effective decision got looser: deny → ask or auto, ask → auto.
    static func signOff(_ live: Policy, _ proposed: Policy) -> [String] {
        func rules(_ policy: Policy) -> [String: PolicyDecision] {
            var out: [String: PolicyDecision] = [:]
            for rule in policy.rules where rule.binding == nil { out[rule.action] = rule.decision }
            return out
        }
        let old = rules(live)
        let new = rules(proposed)
        var out: [String] = []
        if strictness(proposed.default) < strictness(live.default) {
            out.append(
                "actions without a rule go from \(live.default.rawValue) to "
                    + proposed.default.rawValue)
        }
        for action in Set(old.keys).union(new.keys).sorted() {
            let before = old[action] ?? live.default
            let after = new[action] ?? proposed.default
            guard strictness(after) < strictness(before) else { continue }
            out.append(
                before == .deny
                    ? "\(action) no longer blocked" : "sign-off no longer required for \(action)")
        }
        return out
    }

    /// "autonomy raised from suggest to act_low", when the level goes up or is dropped.
    static func autonomy(_ live: Autonomy?, _ proposed: Autonomy?) -> String? {
        guard let live else { return nil }
        guard let proposed else { return "autonomy no longer limited (was \(live.rawValue))" }
        let order = Autonomy.allCases
        guard let from = order.firstIndex(of: live), let to = order.firstIndex(of: proposed),
            to > from
        else { return nil }
        return "autonomy raised from \(live.rawValue) to \(proposed.rawValue)"
    }

    static func strictness(_ decision: PolicyDecision) -> Int {
        switch decision {
        case .deny: 2
        case .ask: 1
        case .auto: 0
        }
    }
}

extension ProposalSummary {
    private enum Keys: String, CodingKey {
        case id, steward, baseVersion, candidateVersion, reason, author, status, verdict
        case acceptable, impact, removed, detail
    }

    /// Decodes summaries written before `impact`, `removed`, and `detail` existed.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            steward: try c.decode(String.self, forKey: .steward),
            baseVersion: try c.decode(Int.self, forKey: .baseVersion),
            candidateVersion: try c.decode(Int.self, forKey: .candidateVersion),
            reason: try c.decodeIfPresent(String.self, forKey: .reason),
            author: try c.decode(String.self, forKey: .author),
            status: try c.decode(String.self, forKey: .status),
            verdict: try c.decodeIfPresent(GateVerdictSummary.self, forKey: .verdict),
            acceptable: try c.decode(Bool.self, forKey: .acceptable))
        impact = try c.decodeIfPresent([String].self, forKey: .impact) ?? []
        removed = try c.decodeIfPresent([String].self, forKey: .removed) ?? []
        detail = try c.decodeIfPresent(ProposalImpact.self, forKey: .detail)
    }

    /// Fills `impact`, `removed`, and `detail` from the proposed charter against `live`.
    mutating func measure(_ proposed: Charter, against live: Charter?) {
        guard let live else { return }
        let found = ProposalImpact(live: live, proposed: proposed)
        impact = found.kinds
        removed = found.removed
        detail = found
    }
}
