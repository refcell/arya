import AryaDesign
import Foundation

/// Time formatting for feature views. Takes `now` explicitly so output is deterministic.
enum FeatureTime {
    /// The one time rule for rows and meta lines (`AryaTime.label`): "now", "2m", "3h", "Nov 8".
    static func relative(_ date: Date, now: Date) -> String {
        AryaTime.label(date, now: now)
    }

    /// The same rule inside a sentence: "just now", "2m ago", "3h ago", "Nov 8".
    static func phrase(_ date: Date, now: Date) -> String {
        AryaTime.label(date, now: now, style: .long)
    }

    /// An absolute time for tooltips: "9 Nov 2026, 14:02".
    static func absolute(_ date: Date, timeZone: TimeZone = .current) -> String {
        AryaTime.absolute(date, timeZone: timeZone)
    }

    /// A short duration: "850 ms", "4.2 s", "3m 5s".
    static func duration(_ seconds: Double) -> String {
        if seconds < 1 { return "\(Int((seconds * 1000).rounded())) ms" }
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        let whole = Int(seconds.rounded())
        return "\(whole / 60)m \(whole % 60)s"
    }
}
