import Foundation

/// The one humanizer every lane uses (run pane, Needs you, inspector, palette): refs as names,
/// action kinds as verbs, actions as sentences, adapters by name.
enum HumanText {
    /// "person:alex" -> "Alex", "tracker:ISSUE-7" -> "ISSUE-7".
    static func name(_ ref: String) -> String { EntityName.plain(ref) }

    /// A tool as a step a person would name: "inbox.search" is "Search the inbox", "crm.get"
    /// is "Read the CRM"; a tool without a system is its verb ("run_tests" is "Run tests").
    static func tool(_ tool: String) -> String {
        let parts = tool.split(separator: ".").map(String.init)
        guard parts.count >= 2, let system = parts.first, let last = parts.last else {
            return capitalized(RunTitle.verb(tool))
        }
        let verb = toolVerbs[last] ?? RunTitle.verb(last)
        return capitalized(verb) + " the " + systemName(system)
    }

    /// An action as a step, in the thread's words: its verb and what it touches by name
    /// ("Label MSG-137", "Reply to Priya").
    static func step(kind: String, target: String) -> String {
        let name = EntityName.plain(target)
        return name.isEmpty ? stepVerb(kind) : stepVerb(kind) + " " + name
    }

    /// An action's verb as the thread leads with it before the target: "Label", "Reply to".
    static func stepVerb(_ kind: String) -> String {
        capitalized(RunTitle.verb(kind)) + (ActionWords.isMessage(kind) ? " to" : "")
    }

    /// `text` cut at the last word end that fits in `max` characters, with an ellipsis; a path
    /// or a hyphenated name may also end at a `/` or `-`. Never mid-word unless the first word
    /// alone is too long.
    static func clip(_ text: String, max: Int) -> String {
        guard text.count > max, max > 1 else { return text }
        let head = text.prefix(max - 1)
        if " /-".contains(text[head.endIndex]) { return head + "…" }
        guard let space = head.lastIndex(where: { " /-".contains($0) }),
            space > head.startIndex
        else {
            return head + "…"
        }
        return String(head[..<space]).trimmingCharacters(in: .punctuationCharacters) + "…"
    }

    private static let toolVerbs = ["get": "read", "fetch": "read", "ls": "list", "rm": "remove"]

    private static func systemName(_ system: String) -> String {
        let words = system.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return words.count <= 3 ? words.uppercased() : words.lowercased()
    }

    private static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Why a run failed, in words: "budget (max_cost_micros: 22149 > 0)" reads "over budget:
    /// spent $0.02, limit $0.00"; other `snake_case` keys read as words.
    static func failure(_ reason: String) -> String {
        let pattern = #"max_cost_micros:\s*(\d+)\s*>\s*(\d+)"#
        if let match = reason.range(of: pattern, options: .regularExpression) {
            let numbers = reason[match].split { !$0.isNumber }.compactMap { Double($0) }
            if numbers.count == 2 {
                return "over budget: spent \(dollars(numbers[0])), limit \(dollars(numbers[1]))"
            }
        }
        return reason.replacingOccurrences(of: "_", with: " ")
    }

    private static func dollars(_ micros: Double) -> String {
        "$" + String(format: "%.2f", micros / 1_000_000)
    }

    /// The ids the person at this home goes by, with or without a kind.
    static let localIDs: Set<String> = ["local", "human:local", "person:local"]

    /// Who did something, the one rule for every "by …": the person at this home is "you",
    /// a person reads as their name ("person:priya" is "Priya"), anyone else by their ref.
    static func actor(_ id: String) -> String {
        if localIDs.contains(id) { return "you" }
        for prefix in ["person:", "human:"] where id.hasPrefix(prefix) {
            let bare = id.dropFirst(prefix.count)
            return bare.prefix(1).uppercased() + bare.dropFirst()
        }
        return EntityName.plain(id)
    }

    /// `actor(_:)` for an event's actor: a human's id is a person.
    static func actor(_ actor: FeatureActor) -> String {
        actor.kind == .human ? Self.actor("person:" + actor.id) : Self.actor(actor.id)
    }

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
