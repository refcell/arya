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

    /// The approve button for any action kind, naming the effect and never a bare noun:
    /// "Approve and send email", "Approve and run the routine", "Approve the webhook". A
    /// question is just "Approve".
    static func approveLabel(kind: String, params: FeatureJSON = .null) -> String {
        if kind == "question" { return "Approve" }
        return "Approve and " + effect(kind: kind, params: params)
    }

    /// What approving does, as a verb phrase: "send email", "run the routine".
    static func effect(kind: String, params: FeatureJSON = .null) -> String {
        let words = verb(kind)
        if kind == "routine" {
            return params["version"] != nil ? "update the routine" : "run the routine"
        }
        if let phrase = nounEffects[words] { return phrase }
        let first = words.split(separator: " ").first.map(String.init) ?? words
        if verbs.contains(first) { return words }
        return "carry out the \(words)"
    }

    /// Action kinds that are nouns, with what approving them does.
    static let nounEffects: [String: String] = [
        "email": "send the email", "message": "send the message", "note": "add the note",
        "ticket": "open the ticket", "issue": "open the issue",
        "invoice": "send the invoice", "report": "send the report", "draft": "save the draft",
        "reminder": "set the reminder", "task": "create the task", "meeting": "book the meeting",
        "event": "create the event", "payment": "make the payment", "credit": "issue the credit",
        "discount": "apply the discount", "escalation": "escalate", "handoff": "hand it off",
        "hand off": "hand it off", "webhook": "call the webhook", "notification": "notify",
        "summary": "post the summary", "digest": "send the digest", "status": "update the status",
        "followup": "follow up", "follow up": "follow up", "reply all": "reply to all",
    ]

    /// Verbs an action kind can start with ("send_email", "label", "close").
    static let verbs: Set<String> = [
        "add", "apply", "approve", "archive", "ask", "assign", "book", "call", "cancel", "change",
        "charge", "close", "comment", "create", "credit", "decline", "delete", "deploy",
        "disqualify", "draft", "edit", "email", "escalate", "file", "flag", "follow", "forward",
        "grant", "hand", "hold", "invite", "issue", "label", "link", "log", "make", "mark", "merge",
        "message", "move", "notify", "open", "pause", "pay", "pin", "post", "publish",
        "qualify", "reassign", "record", "refund", "reject", "release", "remind", "remove",
        "reopen", "reply", "request", "resolve", "restart", "retry", "revert", "revoke",
        "route", "run", "save", "schedule", "send", "set", "share", "snooze", "start", "stop",
        "submit",
        "tag", "tell", "transfer", "carry", "triage", "unassign", "update", "upgrade", "void",
        "write",
    ]

    /// A workspace change line in words: "input: none → ORDER-1218" for a routine reads
    /// "Routine label-duplicates for ORDER-1218"; "label: none → bug" reads "label: bug".
    static func change(_ text: String, kind: String, params: FeatureJSON = .null) -> String {
        let parts = text.components(separatedBy: " → ")
        guard parts.count == 2, parts[0].hasSuffix(": none") else { return sentence(text) }
        let key = String(parts[0].dropLast(": none".count))
        let value = name(parts[1])
        if kind == "routine", key == "input" {
            let routine = params["name"]?.string.map { "Routine \($0)" } ?? "Routine"
            return "\(routine) for \(value)"
        }
        return "\(key): \(value)"
    }
}
