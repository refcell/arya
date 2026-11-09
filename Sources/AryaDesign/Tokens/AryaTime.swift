import Foundation

/// The one way the app writes a time (STYLE.md Time): relative under 24 hours, clock time after.
/// Feature views use `label` and `clock`, never their own formatters, so every screen reads the
/// same. `relative` and `absolute` remain for current callers until they move to `label`.
extension AryaTime {
    /// Where the time sits.
    public enum Style: Sendable {
        /// Rows, cells, and meta lines, the default: "now", "12m", "3h", "Nov 8", "Nov 8, 2025".
        case short
        /// Inside a sentence ("Changed 3h ago", "Ready since Nov 8"): "just now", "12m ago",
        /// "3h ago", then the date as in `short`.
        case long
    }

    /// The one time rule (STYLE.md Time): relative under 24 hours, then the date, with the
    /// year only when it is not the current one. A date in the future counts as now.
    public static func label(
        _ date: Date, now: Date, style: Style = .short, timeZone: TimeZone = .current
    ) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 86_400 {
            let short: String
            switch seconds {
            case ..<60: return style == .short ? "now" : "just now"
            case ..<3600: short = "\(seconds / 60)m"
            default: short = "\(seconds / 3600)h"
            }
            return style == .short ? short : short + " ago"
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return clock(date, format: sameYear ? "MMM d" : "MMM d, yyyy", timeZone: timeZone)
    }

    /// Clock time alone, "14:27", for step gutters in a transcript; "14:27:05" with `seconds`
    /// where steps land within the same minute.
    public static func clock(
        _ date: Date, seconds: Bool = false, timeZone: TimeZone = .current
    ) -> String {
        clock(date, format: seconds ? "HH:mm:ss" : "HH:mm", timeZone: timeZone)
    }

    private static func clock(_ date: Date, format: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
