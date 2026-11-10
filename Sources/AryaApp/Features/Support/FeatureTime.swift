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

    /// A short duration, the one format for every elapsed clock (status bar, NOW, inspector):
    /// "850 ms", "4.2 s", "3m 5s", "1h 12m".
    static func duration(_ seconds: Double) -> String {
        if seconds < 1 { return "\(Int((max(0, seconds) * 1000).rounded())) ms" }
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        let whole = Int(seconds.rounded())
        if whole >= 3600 { return "\(whole / 3600)h \(whole % 3600 / 60)m" }
        return "\(whole / 60)m \(whole % 60)s"
    }
}
