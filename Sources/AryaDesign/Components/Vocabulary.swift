import Foundation

/// The state of a steward, run, or step as the interface shows it: a dot paired with a word.
public enum AryaStatus: String, CaseIterable, Sendable {
    case running, waiting, failed, done, idle, paused, denied, executed, passed
    /// Steward health in the sidebar: something waits on a person, or the metric meets or
    /// misses its target.
    case needsYou, onTrack, offTrack

    /// The word shown beside the dot. Status is never color alone.
    public var word: String {
        switch self {
        case .needsYou: "needs you"
        case .onTrack: "on track"
        case .offTrack: "off track"
        default: rawValue
        }
    }

    /// The dot's color token. Only `running` is accented (the live indicator).
    public var dotToken: AryaColorToken {
        switch self {
        case .running: .accent
        case .needsYou: .accentFill
        case .failed, .denied, .offTrack: .negative
        case .done, .executed, .passed, .onTrack: .positive
        case .waiting, .idle, .paused: .inkFaint
        }
    }

    /// Whether the dot pulses (only the live indicator does, and not under Reduce Motion).
    public var isLive: Bool { self == .running }

    /// Whether the dot is an outline (paused: present but not working).
    public var isHollow: Bool { self == .paused }
}

/// A proposal's gate policy.
public enum AryaPolicy: String, CaseIterable, Sendable {
    case auto, ask, deny

    /// The chip's text color token; the word is always shown too.
    public var textToken: AryaColorToken {
        switch self {
        case .auto: .positive
        case .ask: .accent
        case .deny: .negative
        }
    }

    /// The chip's border token: `accent` for `ask`, the plain chip rule otherwise.
    public var borderToken: AryaColorToken { self == .ask ? .accent : .rule }
}

/// How hard a run works. Adapters map each level to a model.
public enum AryaEffort: String, CaseIterable, Sendable, Identifiable {
    case low, medium, high

    public var id: String { rawValue }
    public var label: String { rawValue }

    /// The one-line trade-off shown as the selector's tooltip.
    public static let tooltip = "More effort: slower, more thorough runs"
}

/// Relative and absolute timestamps as STYLE.md writes them ("2m ago", "9 Nov 2026, 14:02").
/// Pure functions of their inputs so views and tests stay deterministic.
public enum AryaTime {
    /// A relative time for lists: "just now", "2m ago", "3h ago", "5d ago". New code uses
    /// `label(_:now:)`, which switches to a clock time after a day.
    public static func relative(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
    }

    /// A ledger timestamp (`2026-10-09T09:00:00Z`) as a date; nil when it is not one.
    public static func parse(iso text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }

    /// An absolute time for tooltips, in a given time zone.
    public static func absolute(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let months = [
            "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        ]
        let month = months[((parts.month ?? 1) - 1) % 12]
        let time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        return "\(parts.day ?? 1) \(month) \(parts.year ?? 1970), \(time)"
    }

    /// A step sequence number, zero-padded to two digits.
    public static func sequence(_ number: Int) -> String {
        number < 10 && number >= 0 ? "0\(number)" : "\(number)"
    }
}

/// Shortening text without cutting a word: "5 tools, every one read-only" at 16 reads
/// "5 tools, every…", never "5 tools, ev…".
public enum AryaTrim {
    public static func words(_ text: String, limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard flat.count > limit else { return flat }
        let head = flat.prefix(limit)
        let cut = head.lastIndex(where: \.isWhitespace) ?? head.endIndex
        let kept = head[..<cut].trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        return (kept.isEmpty ? String(head) : kept) + "…"
    }
}
