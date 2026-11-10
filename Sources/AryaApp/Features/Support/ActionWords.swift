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
}
