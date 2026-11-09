import Foundation

/// Time formatting for feature views. Takes `now` explicitly so output is deterministic.
enum FeatureTime {
    /// A relative time for lists: "just now", "2m ago", "3h ago", "5d ago".
    static func relative(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
    }

    /// An absolute time for tooltips: "9 Nov 2026, 14:02".
    static func absolute(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        return formatter.string(from: date)
    }

    /// A short duration: "850 ms", "4.2 s", "3m 5s".
    static func duration(_ seconds: Double) -> String {
        if seconds < 1 { return "\(Int((seconds * 1000).rounded())) ms" }
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        let whole = Int(seconds.rounded())
        return "\(whole / 60)m \(whole % 60)s"
    }
}
