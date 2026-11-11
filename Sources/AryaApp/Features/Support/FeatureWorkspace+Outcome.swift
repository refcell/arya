import Arya
import Foundation

// Feature workspace reads owned by app-outcome (Improve): routines, cases, what if, the
// review queue, backtests, and learned checks.
// One file per lane so lanes stop colliding in FeatureWorkspace.swift; add requirements and
// their defaults here.

/// The Improve screen as the workspace writes it: the rehearsal and readiness in sentences,
/// and each case's result, expectation, and difference in words.
struct FeatureImproveSummary: Hashable, Sendable {
    struct Case: Hashable, Sendable {
        var id: String
        var wouldHave: String
        var expected: String
        var diff: String
        var passed: Bool
        var leak: Bool
    }

    var rehearsal: String?
    var rehearsalText: String
    var ready: Bool
    var markedReady: Bool
    var readinessText: String
    var readinessReasons: [String]
    var cases: [Case]
    /// Gate text by proposal id.
    var gates: [String: String]
}

/// The review queue as the workspace writes it: what the steward would have done next to what
/// the person did, case by case, with progress. Every string is shown verbatim.
struct FeatureReviewQueue: Hashable, Sendable {
    struct Item: Hashable, Sendable, Identifiable {
        var id: String
        var input: String
        var wouldHave: String
        var personDid: String
        /// Whether the steward matched; nil before the case was rehearsed.
        var matches: Bool?
        var difference: String
        var source: String
        /// `pending`, `agreed`, `corrected`, or `skipped`.
        var status: String
    }

    var casebookVersion: String
    var rehearsal: String?
    var progressText: String
    var total: Int
    var reviewed: Int
    var next: Item?
}

/// The checks people taught a steward by correcting and agreeing, scored on its newest live
/// rehearsal. Every string is shown verbatim.
struct FeatureLearnedChecks: Hashable, Sendable {
    struct Line: Hashable, Sendable, Identifiable {
        var id: String
        var caseID: String
        /// The person's note for a correction, else the expectation in words.
        var text: String
        /// nil when the rehearsal has no answer for the case.
        var passed: Bool?
        /// What the steward did on that field: `choice: bug`, or `not rehearsed`.
        var found: String
        /// `corrected` or `agreed`.
        var origin: String
        /// The result in one line: `Breaks “…” on case-0006: choice: bug, not billing.`
        var result: String = ""
    }

    var version: Int
    var sentence: String
    var total: Int
    var scored: Int
    var passed: Int
    /// Failing first, then unscored, then passing.
    var lines: [Line]
}

/// What worked (eval's trajectory grading): runs graded on follow-up checks that came later,
/// with credit for action kinds and decision choices. Every string is shown verbatim.
struct FeatureTrajectories: Hashable, Sendable {
    struct Credit: Hashable, Sendable, Identifiable {
        var id: String
        /// `kind` or `choice`.
        var axis: String
        var name: String
        var resolved: Int
        var reopened: Int
        var pending: Int
        /// resolved / settled, nil until one settles.
        var rate: Double?
        /// 0...1, the lower end of the 95% interval on `rate`.
        var confidence: Double
        var medianLagDays: Double?
        /// `label: resolved 10 of 12, checked a median 9 days later`.
        var line: String
    }

    var good: Int
    var bad: Int
    var pending: Int
    var sentence: String
    /// Kinds, then choices, each by confidence.
    var credits: [Credit]
}

/// Whether a steward is ready to go live after onboarding (eval's go-live gate): agreed
/// reviews, a passing rehearsal, and green checks, with the one sentence of what is missing.
struct FeatureGoLiveGate: Hashable, Sendable {
    struct Condition: Hashable, Sendable, Identifiable {
        /// `review`, `rehearsal`, or `checks`.
        var key: String
        var met: Bool
        var detail: String
        var id: String { key }
    }

    var ready: Bool
    var summary: String
    var conditions: [Condition]
}

/// A proposed charter change from the editor.
struct CharterProposal: Hashable, Sendable {
    var steward: String
    /// The live version the draft started from.
    var baseVersion: Int
    var charter: FeatureJSON
    var title: String
    var reason: String
}

/// A correction of one rehearsed case.
struct CaseCorrection: Hashable, Sendable {
    var steward: String
    var casebook: String
    var caseID: String
    var text: String
    var expected: FeatureJSON?
    var rehearsal: String?
    var run: String?
}

/// A proposal's backtest against the live charter (eval's live readiness), shown verbatim.
struct FeatureLiveReadiness: Hashable, Sendable {
    var ready: Bool
    /// One sentence, for example `Not ready: case-0005 would regress`.
    var summary: String
    /// One line per regressed case.
    var regressions: [String]
    /// Ids of cases that would improve.
    var improved: [String]
    /// Recent live runs replayed under the proposal.
    var runsChecked: Int
}

/// The app-outcome lane's reads; `FeatureWorkspace` inherits them.
protocol FeatureOutcomeReads: Sendable {
    /// The body of one routine version (a content-addressed blob), or nil if it is missing.
    func routineContent(steward: String, name: String, version: String) async throws -> String?
    /// The expected result of one case in a casebook version, or nil if it is missing.
    func caseExpected(casebook: String, caseID: String) async throws -> FeatureJSON?
    /// What `run` would have done under a proposal's charter, in one line.
    func whatIf(run: String, proposal: String) async throws -> String
    /// The Improve screen's sentences for one steward, written by the workspace.
    func improveSummary(steward: String) async throws -> FeatureImproveSummary
    /// The review queue for one steward, or nil when it has no casebook.
    func reviewQueue(steward: String) async throws -> FeatureReviewQueue?
    /// The learned checks for one steward, or nil before anyone reviewed a case.
    func learnedChecks(steward: String) async throws -> FeatureLearnedChecks?
    /// A charter proposal backtested against the live charter, for Improve.
    func liveReadiness(proposal: String) async throws -> FeatureLiveReadiness
    /// What worked: runs graded on later outcomes, credit by kind and choice (eval).
    func trajectories(steward: String) async throws -> FeatureTrajectories
    /// The go-live gate for onboarding (eval).
    func goLiveGate(steward: String) async throws -> FeatureGoLiveGate
    /// What the steward is doing now (app-outcome's NOW).
    func stewardLive(steward: String) async throws -> FeatureStewardLive
    /// The Overview's findings, the steward's own first (app-outcome's FINDINGS).
    func overviewFindings(steward: String) async throws -> [FeatureOverviewFinding]
    /// Which actions moved the metric, nil without enough readings (app-outcome's IMPACT).
    func impact(steward: String) async throws -> FeatureImpact?
    /// Imports a binding's past items into the steward's casebook; the workspace's one line.
    func importHistory(steward: String, binding: String) async throws -> String
    /// The steward's onboarding steps, notes, and go-live gate.
    func onboarding(steward: String) async throws -> FeatureOnboarding
    /// Runs an onboard run now (it reads people and process); the workspace's one line.
    func runOnboarding(steward: String) async throws -> String
    /// The primary metric and each guardrail metric over the last `windows` days.
    func metricStatuses(steward: String, windows: Int) async throws -> [FeatureMetricStatus]
    /// The evaluation window's `missed its target on 4 of the last 7 days`, verbatim; nil
    /// when nothing missed.
    func outcomeMissedText(steward: String) async throws -> String?
}

extension FeatureOutcomeReads {
    /// Workspaces without a blob read report that routine bodies are not available yet.
    func routineContent(steward: String, name: String, version: String) async throws -> String? {
        throw FeatureReadError.unavailable("routine bodies")
    }

    /// Workspaces without a casebook read report that expected results are not available yet.
    func caseExpected(casebook: String, caseID: String) async throws -> FeatureJSON? {
        throw FeatureReadError.unavailable("expected results")
    }

    /// Workspaces without counterfactual runs report What if as unavailable.
    func whatIf(run: String, proposal: String) async throws -> String {
        throw FeatureReadError.unavailable("What if")
    }

    /// Workspaces without an Improve read report it unavailable; the screen then projects
    /// the ledger itself.
    func improveSummary(steward: String) async throws -> FeatureImproveSummary {
        throw FeatureReadError.unavailable("improve summary")
    }

    /// Workspaces without a backtest read report it unavailable; the proposal then shows only
    /// its gate.
    func liveReadiness(proposal: String) async throws -> FeatureLiveReadiness {
        throw FeatureReadError.unavailable("backtest")
    }

    /// Workspaces without a review queue report it unavailable; Improve then hides it.
    func reviewQueue(steward: String) async throws -> FeatureReviewQueue? {
        throw FeatureReadError.unavailable("review queue")
    }

    /// Workspaces without learned checks report them unavailable; Improve then hides them.
    func learnedChecks(steward: String) async throws -> FeatureLearnedChecks? {
        throw FeatureReadError.unavailable("learned checks")
    }

    /// Workspaces without trajectory grading report it unavailable; Improve then hides it.
    func trajectories(steward: String) async throws -> FeatureTrajectories {
        throw FeatureReadError.unavailable("trajectories")
    }

    /// Workspaces without the go-live gate report it unavailable; onboarding then hides it.
    func goLiveGate(steward: String) async throws -> FeatureGoLiveGate {
        throw FeatureReadError.unavailable("go-live gate")
    }

    func stewardLive(steward: String) async throws -> FeatureStewardLive {
        throw FeatureReadError.unavailable("steward live")
    }

    func overviewFindings(steward: String) async throws -> [FeatureOverviewFinding] {
        throw FeatureReadError.unavailable("findings")
    }

    func impact(steward: String) async throws -> FeatureImpact? {
        throw FeatureReadError.unavailable("impact")
    }

    func importHistory(steward: String, binding: String) async throws -> String {
        throw FeatureReadError.unavailable("history import")
    }

    func onboarding(steward: String) async throws -> FeatureOnboarding {
        throw FeatureReadError.unavailable("onboarding")
    }

    func runOnboarding(steward: String) async throws -> String {
        throw FeatureReadError.unavailable("onboarding")
    }

    func metricStatuses(steward: String, windows: Int) async throws -> [FeatureMetricStatus] {
        throw FeatureReadError.unavailable("metric statuses")
    }

    func outcomeMissedText(steward: String) async throws -> String? {
        throw FeatureReadError.unavailable("outcome window")
    }
}
