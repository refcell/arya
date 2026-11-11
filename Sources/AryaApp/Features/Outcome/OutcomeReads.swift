import Foundation

// The Overview's workspace reads (one source per fact): NOW from `stewardLive(steward:)`,
// FINDINGS from `overviewFindings(steward:)`, IMPACT from `impact(steward:)`. The app maps
// them; it does not compute these facts itself.

/// What a steward is doing now (`Workspace.stewardLive`).
struct FeatureStewardLive: Hashable, Sendable {
    /// The newest run in progress, as app-views' run facts wrapper.
    var running: FeatureRunFacts?
    /// That run's id, title, and progress estimate (0...1), from the same read.
    var run: String?
    var title: String?
    var progress: Double?
    var alsoRunning: Int
    /// off, unscheduled, running, due, or waiting.
    var schedule: String
    var nextWake: Date?
    var serving: Bool
}

/// A FINDINGS line (`Workspace.overviewFindings`).
struct FeatureOverviewFinding: Hashable, Sendable {
    /// problem, opportunity, attention, negative, positive, or info.
    var kind: String
    var text: String
    /// What the line opens (approval, run, proposal, finding), when anything.
    var link: String? = nil
}

/// Which actions moved the metric (`Workspace.impact`), with confidence.
struct FeatureImpact: Hashable, Sendable {
    struct Row: Hashable, Sendable {
        var label: String
        var credit: Double
        var helped: Bool
        /// high, medium, or low.
        var confidence: String
        /// The workspace's own line, shown verbatim: "label: +0.040 over 12 actions in 5 of 7
        /// windows, medium confidence".
        var line: String
    }

    var readings: Int
    var rows: [Row]
    /// The honest one-line summary, used when no row splits out.
    var summary: String
}

/// The Overview's reads for one steward, loaded once per ledger revision.
struct OutcomeReads: Hashable, Sendable {
    var live: FeatureStewardLive?
    var findings: [FeatureOverviewFinding]?
    var impact: FeatureImpact?
    var onboarding: FeatureOnboarding?
    var metrics: [FeatureMetricStatus]?
    /// The evaluation window's missed line (`outcomeWindow.missedText`): `.some(nil)` when
    /// read and nothing missed, nil when not read.
    var missedText: String?? = nil

    /// Runs per day over 7 days (`runHistory`), the one source for run counts.
    var runs: FeatureRunHistory? = nil

    /// The primary metric's status read.
    var primary: FeatureMetricStatus? { metrics?.first { $0.role == "primary" } }
}

/// A steward's onboarding as the workspace reports it (`onboardingState`, the latest onboard
/// run, and the notes it wrote); the app shows each line verbatim. The go-live gate is eval's
/// `FeatureGoLiveGate` read.
struct FeatureOnboarding: Hashable, Sendable {
    struct Step: Hashable, Sendable {
        /// `systems`, `people`, `processes`, `notes`, `history`, `review`, or `ready`.
        var key: String
        var title: String
        var done: Bool
        var detail: String
    }

    /// One context note: who or what it is about, and its text.
    struct Note: Hashable, Sendable {
        var about: String
        var text: String
    }

    var steps: [Step]
    var summary: String
    var notes: [Note]
    /// When it last ran an onboard run, if ever.
    var onboardedAt: Date?

    func step(_ key: String) -> Step? { steps.first { $0.key == key } }
}

/// One of the charter's metrics, the primary or a guardrail, as the workspace scores it
/// (`Workspace.metricStatuses`) over the panel's window.
struct FeatureMetricStatus: Hashable, Sendable {
    var name: String
    var unit: String
    /// `up` or `down`: which way is better.
    var direction: String
    var target: Double?
    /// `primary` or `guardrail`.
    var role: String
    var current: Double?
    /// One value per window, oldest first; nil where nothing was recorded.
    var trend: [Double?]
    /// `on_track`, `off_track`, `no_target`, or `no_data`.
    var status: String
    /// `improving`, `worsening`, `flat`, or `unknown`.
    var movement: String
    /// `reply_minutes 42 minutes, target ≤ 60: on track, improving.`
    var line: String
}

/// A steward's runs on each of the last 7 local days (`Workspace.runHistory`), the same read the
/// inspector and portfolio bars use.
struct FeatureRunHistory: Hashable, Sendable {
    /// Top-level live runs per day, oldest first; the last is today.
    var runs: [Int]
    /// Of those, the failed ones.
    var failed: [Int]
    var failedTotal: Int
    /// Shown verbatim: `14 runs in 7 days, 2 today, 1 failed`.
    var line: String
}
