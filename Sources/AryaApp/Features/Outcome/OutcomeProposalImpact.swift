/// What a charter proposal does to the steward's safety, from the proposed charter against the
/// live one: whether it changes what the steward owns (the outcome sentence or the metric and
/// target), and what it removes or loosens (guardrails, sign-off, blocked actions, the
/// adapter). Either one keeps Accept quiet behind a confirm.
struct ProposalImpact: Hashable, Sendable {
    /// "“old outcome” → “new outcome”", "metric x ≥ 0.95 → x ≥ 0.90".
    var owns: [String] = []
    /// Guardrails the proposal drops, verbatim.
    var removedGuardrails: [String] = []
    /// "sign-off no longer required for refund", "adapter a → b".
    var loosened: [String] = []
    /// Changes that keep every decision: "drops the explanation on 5 sign-off rules".
    var neutral: [String] = []

    var changesOwnership: Bool { !owns.isEmpty }
    var loosens: Bool { !removedGuardrails.isEmpty || !loosened.isEmpty }
    /// Accept must not be the default: it stays quiet and asks for a confirm.
    var needsConfirm: Bool { changesOwnership || loosens }

    /// "This changes what the steward owns: “…” → “…”."
    var ownsSentence: String? {
        owns.isEmpty
            ? nil
            : Self.sentence("This changes what the steward owns: \(owns.joined(separator: "; "))")
    }

    /// "Sign-off decisions stay the same; drops the explanation on 5 rules."
    var neutralSentence: String? {
        guard let first = neutral.first else { return nil }
        return Self.sentence(
            ([first.prefix(1).uppercased() + first.dropFirst()] + neutral.dropFirst())
                .joined(separator: "; "))
    }

    /// Ends `text` with a period unless it already ends in punctuation, inside a quote or not.
    static func sentence(_ text: String) -> String {
        var tail = text
        while let last = tail.last, "”\"’')".contains(last) { tail.removeLast() }
        return tail.last.map { ".!?".contains($0) } == true ? text : text + "."
    }

    /// "Removes 2 guardrails: “…”, “…”; sign-off no longer required for refund."
    var loosensSentence: String? {
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
        return Self.sentence(text)
    }

    static func build(live: FeatureJSON, proposed: FeatureJSON) -> ProposalImpact {
        var impact = ProposalImpact()
        let oldOutcome = live["outcome"]?.string ?? ""
        let newOutcome = proposed["outcome"]?.string ?? ""
        if oldOutcome != newOutcome {
            impact.owns.append("“\(oldOutcome)” → “\(newOutcome)”")
        }
        if live["metric"] != proposed["metric"] {
            impact.owns.append("metric \(metric(live["metric"])) → \(metric(proposed["metric"]))")
        }
        let kept = Set(proposed["guardrails"]?.strings ?? [])
        impact.removedGuardrails = (live["guardrails"]?.strings ?? []).filter { !kept.contains($0) }
        impact.loosened = signOff(live["policy"], proposed["policy"])
        let dropped = droppedNotes(live["policy"], proposed["policy"])
        if dropped > 0 {
            let noun = dropped == 1 ? "rule" : "rules"
            impact.neutral.append(
                (impact.loosened.isEmpty ? "sign-off decisions stay the same; " : "")
                    + "drops the explanation on \(dropped) \(noun)")
        }
        let oldAdapter = live["adapter"]?.string ?? ""
        let newAdapter = proposed["adapter"]?.string ?? ""
        if oldAdapter != newAdapter {
            impact.loosened.append("adapter \(oldAdapter) → \(newAdapter)")
        }
        return impact
    }

    static func build(_ item: ProposalItem, events: [FeatureEvent]) -> ProposalImpact {
        guard let steward = item.steward,
            let proposed = ProposalText.proposedCharter(item, events: events),
            let live = LiveCharter.find(events: events, steward: steward)?.charter
        else { return ProposalImpact() }
        return build(live: live, proposed: proposed)
    }

    /// "routed_within_1h ≥ 0.95", or "none".
    static func metric(_ json: FeatureJSON?) -> String {
        guard let name = json?["name"]?.string else { return "none" }
        guard let target = json?["target"]?.number else { return name }
        let sign = json?["direction"]?.string == "down" ? "≤" : "≥"
        return "\(name) \(sign) \(MetricText.value(target))"
    }

    /// Actions whose effective decision got looser: deny → ask or auto, ask → auto.
    static func signOff(_ live: FeatureJSON?, _ proposed: FeatureJSON?) -> [String] {
        func rules(_ policy: FeatureJSON?) -> [String: String] {
            var out: [String: String] = [:]
            for rule in policy?["rules"]?.array ?? [] {
                if let action = rule["action"]?.string, let decision = rule["decision"]?.string {
                    out[action] = decision
                }
            }
            return out
        }
        let oldRules = rules(live)
        let newRules = rules(proposed)
        let oldDefault = live?["default"]?.string ?? "ask"
        let newDefault = proposed?["default"]?.string ?? "ask"
        var out: [String] = []
        if strictness(newDefault) < strictness(oldDefault) {
            out.append("actions without a rule go from \(oldDefault) to \(newDefault)")
        }
        for action in Set(oldRules.keys).union(newRules.keys).sorted() {
            let before = oldRules[action] ?? oldDefault
            let after = newRules[action] ?? newDefault
            guard strictness(after) < strictness(before) else { continue }
            out.append(
                before == "deny"
                    ? "\(action) no longer blocked" : "sign-off no longer required for \(action)")
        }
        return out
    }

    /// Rules that keep their action but lose their `note`.
    static func droppedNotes(_ live: FeatureJSON?, _ proposed: FeatureJSON?) -> Int {
        var kept: [String: Bool] = [:]
        for rule in proposed?["rules"]?.array ?? [] {
            if let action = rule["action"]?.string { kept[action] = rule["note"]?.string != nil }
        }
        return (live?["rules"]?.array ?? []).filter { rule in
            guard rule["note"]?.string != nil, let action = rule["action"]?.string else {
                return false
            }
            return kept[action] == false
        }.count
    }

    static func strictness(_ decision: String) -> Int {
        switch decision {
        case "deny": 2
        case "auto": 0
        default: 1
        }
    }
}
