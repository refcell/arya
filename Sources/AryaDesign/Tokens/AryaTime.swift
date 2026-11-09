import Foundation

/// The one way the app writes a time (STYLE.md Time): relative under 24 hours, clock time after.
/// Feature views use `label` and `clock`, never their own formatters, so every screen reads the
/// same. `relative` and `absolute` remain for current callers until they move to `label`.
extension AryaTime {
    /// How much room a label has.
    public enum Style: Sendable {
        /// Sidebar threads and table cells: "now", "4m", "2h", then "Nov 8".
        case short
        /// Prose and detail lines: "just now", "4m ago", "2h ago", then "Nov 8".
        case long
    }

    /// `date` relative to `now` while under 24 hours old, the calendar date after. Clock time
    /// belongs only in transcript gutters (`clock`).
    /// A date in the future counts as now. `timeZone` and the POSIX locale keep it deterministic.
    public static func label(
        _ date: Date, now: Date, style: Style = .long, timeZone: TimeZone = .current
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
        return clock(date, format: "MMM d", timeZone: timeZone)
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
