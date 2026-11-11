import Foundation

/// Machine words as people read them, in one place: `follow_up` and `follow-up` both read
/// "follow-up"; an action line is "Reply inbox:ORDER-1043".
enum ActionWords {
    /// "follow_up" -> "follow-up", "apologize-and-confirm" stays, "" -> "action".
    static func kind(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "action" }
        return trimmed.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    /// "Reply inbox:ORDER-1043", "Refund billing:ORDER-1043"; the target is never shortened.
    static func line(kind raw: String, target: String) -> String {
        let word = kind(raw)
        let title = word.prefix(1).uppercased() + word.dropFirst()
        return target.isEmpty ? title : "\(title) \(target)"
    }

    /// Verb phrases for common kinds; `%@` is the target's plain name.
    static let phrases: [String: String] = [
        "send-email": "Send an email to %@", "email": "Email %@", "reply": "Reply to %@",
        "refund": "Refund %@", "remind": "Remind about %@", "publish": "Publish %@",
        "comment": "Comment on %@", "update": "Update %@", "label": "Label %@",
        "route": "Route %@", "note": "Add a note to %@", "assign": "Assign %@",
        "close": "Close %@", "escalate": "Escalate %@", "follow-up": "Follow up with %@",
        "notify": "Notify %@", "post": "Post to %@", "message": "Message %@",
    ]

    /// An action as a sentence with the target as a name: "send_email" on "lead:LEAD-1095"
    /// reads "Send an email to LEAD-1095"; unknown kinds read "Archive LEAD-1095".
    static func sentence(kind raw: String, target: String) -> String {
        let word = kind(raw)
        let parts = EntityName.split(target)
        // The noun only when the id does not already say it ("LEAD-1095" needs no "lead").
        let noun = parts.system.flatMap { nouns[$0] }
            .flatMap { parts.name.lowercased().hasPrefix($0) ? nil : $0 }
        let name = noun.map { "\($0) \(parts.name)" } ?? parts.name
        if let phrase = phrases[word], !name.isEmpty {
            return phrase.replacingOccurrences(of: "%@", with: name)
        }
        let verb = word.replacingOccurrences(of: "-", with: " ")
        let title = verb.prefix(1).uppercased() + verb.dropFirst()
        return name.isEmpty ? title : "\(title) \(name)"
    }

    /// What a ref's system calls the thing: "inv:INV-1066" is "invoice INV-1066".
    static let nouns: [String: String] = [
        "inv": "invoice", "invoice": "invoice", "lead": "lead", "acct": "account",
        "cmt": "commitment", "vnd": "vendor", "rel": "release", "order": "order",
    ]

    /// A charter's autonomy level as a sentence: `act_medium` reads "Acts alone on medium risk".
    static func autonomy(_ level: String) -> String {
        switch level {
        case "observe": "Watches only, acts on nothing"
        case "suggest": "Suggests; a person acts"
        case "act_low": "Acts alone on low risk"
        case "act_medium": "Acts alone on medium risk"
        default: kind(level).replacingOccurrences(of: "-", with: " ")
        }
    }

    /// Machine text in a sentence as people read it: refs become names and a leading
    /// "Wants to <kind> <ref>" becomes the action's sentence.
    static func humanize(_ text: String) -> String {
        let prefix = "Wants to "
        if text.hasPrefix(prefix) {
            let rest = text.dropFirst(prefix.count)
            let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2,
                parts[0].contains("_") || parts[0].contains("-") || phrases[kind(parts[0])] != nil
            {
                var target = parts[1]
                let stop = target.hasSuffix(".")
                if stop { target.removeLast() }
                let action = sentence(kind: parts[0], target: target)
                return prefix + action.prefix(1).lowercased() + action.dropFirst()
                    + (stop ? "." : "")
            }
        }
        return EntityName.humanize(text)
    }
}
