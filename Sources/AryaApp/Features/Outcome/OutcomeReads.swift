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
    /// When the workspace answered; NOW adds the seconds since to the run's elapsed time, as
    /// the status bar does.
    var readAt: Date? = nil
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
        var actions: Int
        var windows: Int
        /// high, medium, or low.
        var confidence: String
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
}

/// A steward's onboarding as the workspace reports it (`onboardingState`, the latest onboard
/// run, the notes it wrote, and the go-live gate); the app shows each line verbatim.
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

    struct Gate: Hashable, Sendable {
        var ready: Bool
        /// `Not ready: 4 more agreed reviews needed; 2 checks fail.`
        var summary: String
    }

    var steps: [Step]
    var summary: String
    var notes: [Note]
    /// When it last ran an onboard run, if ever.
    var onboardedAt: Date?
    var gate: Gate?

    func step(_ key: String) -> Step? { steps.first { $0.key == key } }
}
