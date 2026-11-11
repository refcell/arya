import Foundation

/// The one humanizer every lane uses (run pane, Needs you, inspector, palette): refs as names,
/// action kinds as verbs, actions as sentences, adapters by name.
enum HumanText {
    /// "person:alex" -> "Alex", "tracker:ISSUE-7" -> "ISSUE-7".
    static func name(_ ref: String) -> String { EntityName.plain(ref) }

    /// Every ref in a sentence as a name: "Assign tracker:ISSUE-7 to person:alex" reads
    /// "Assign ISSUE-7 to Alex".
    static func sentence(_ text: String) -> String { EntityName.humanize(text) }

    /// "send_email" -> "send email".
    static func verb(_ kind: String) -> String { RunTitle.verb(kind) }

    /// "send_email" -> "sent email", "label" -> "labeled".
    static func pastVerb(_ kind: String) -> String {
        let words = verb(kind).split(separator: " ", maxSplits: 1).map(String.init)
        guard let first = words.first else { return kind }
        return ([RunTitle.participle(first)] + words.dropFirst()).joined(separator: " ")
    }

    /// An action as one sentence from its values: "Assign ISSUE-7 to Alex", "Refund 24.00 USD
    /// on ORDER-1043", else "Archive MSG-9".
    static func action(kind: String, target: String, params: FeatureJSON = .null) -> String {
        let step = ProposedActionStep(
            actionID: "", kind: kind, target: target, summary: "", rationale: "", policy: "",
            outcome: .proposed, params: params)
        if let sentence = ActionSummary.sentence(step) { return sentence }
        let words = verb(kind)
        let head = words.prefix(1).uppercased() + words.dropFirst()
        return target.isEmpty ? head : "\(head) \(name(target))"
    }

    /// An adapter profile by its display name ("Triage (test)").
    static func adapter(_ profile: String, named: String? = nil) -> String {
        AdapterName.display(profile, named: named)
    }
}
