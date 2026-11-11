import Arya
import Foundation

// Feature workspace reads owned by app-views (runs): live updates, replay, event detail, run
// facts, and approval words.
// One file per lane so lanes stop colliding in FeatureWorkspace.swift; add requirements and
// their defaults here.

/// What the workspace says about a pending approval: why policy held it, in a sentence (a
/// charter rule's note, a generated sentence, or an autonomy explanation), and what the action
/// would change ("label: none → billing").
struct FeatureApprovalText: Hashable, Sendable {
    var policy: String?
    var change: String?
}

/// One event as the inspector shows it.
struct FeatureEventDetail: Hashable, Sendable {
    /// Where the event sits in its run: its position from 1, the run's event count, and title.
    struct Step: Hashable, Sendable {
        var run: String
        var index: Int
        var count: Int
        var title: String
    }

    var payloadText: String
    var hash: String
    var prev: String
    var step: Step?
}

/// The result of replaying a run from the ledger alone.
struct FeatureReplayResult: Hashable, Sendable {
    /// Where a replay first differed from the recording.
    struct Divergence: Hashable, Sendable {
        /// Position among the run's events, from 0.
        var index: Int
        var seq: Int?
        var type: String
        /// Dotted path of the first differing field, for example `payload.status`.
        var field: String
        /// Recorded and replayed events as canonical JSON, or empty.
        var recorded: String
        var replayed: String
    }

    var run: String
    /// Events compared.
    var events: Int
    /// Empty when the replay matched the recording exactly.
    var divergences: [Divergence]
}

/// One run's numbers as the workspace counts them (`Workspace.runFacts`).
struct FeatureRunFacts: Hashable, Sendable {
    var running: Bool
    var started: Date
    var elapsedSeconds: Double
    var decisions: Int
    var toolCalls: Int
    var actionsProposed: Int
    var actionsApplied: Int
    var actionsDrafted: Int
    var actionsWaiting: Int
    var stepIndex: Int
    var estimatedSteps: Int?
    /// True when the run drafted actions and applied none.
    var dryRun: Bool
    /// Cost so far while running, the recorded cost once ended; nil when none is known.
    var costMicros: Int? = nil
}

extension FeatureRunFacts {
    /// Seconds from start to now while running (the caller's ticking clock), else the
    /// workspace's elapsed time.
    func elapsed(now: Date) -> Double {
        running ? max(0, now.timeIntervalSince(started)) : elapsedSeconds
    }

    /// The one elapsed format for every surface: "850 ms", "8.5 s", "2m 4s"; whole seconds
    /// while running, so a ticking counter does not jitter.
    func elapsedText(now: Date) -> String {
        FeatureRunFacts.elapsedText(elapsed(now: now), running: running)
    }

    static func elapsedText(_ seconds: Double, running: Bool) -> String {
        if running, seconds < 60 { return "\(Int(seconds.rounded(.down))) s" }
        return FeatureTime.duration(seconds)
    }
}

/// The app-views lane's reads; `FeatureWorkspace` inherits them.
protocol FeatureRunReads: Sendable {
    /// Replays a finished run and reports the first difference from the recording.
    func replay(run: String) async throws -> FeatureReplayResult
    /// The workspace's words for each pending approval, by approval id.
    func approvalTexts() async throws -> [String: FeatureApprovalText]
    /// Yields each time a live run's ledger grows, and finishes when the run ends.
    func observeRun(_ run: String) -> AsyncStream<Void>
    /// One event's inspector detail (hash chain, run position, readable payload), or nil.
    func eventDetail(seq: Int) async throws -> FeatureEventDetail?
    /// One run's numbers from the workspace (`Workspace.runFacts`), the one source for counts,
    /// start, elapsed time, and progress; nil when the workspace has none.
    func runFacts(run: String) async throws -> FeatureRunFacts?
}

extension FeatureRunReads {
    /// Workspaces without run facts leave the numbers to the ledger projection.
    func runFacts(run: String) async throws -> FeatureRunFacts? { nil }

    /// Workspaces without a ledger watch never yield; the run shows as of its last reload.
    func observeRun(_ run: String) -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }

    /// Workspaces without approval summaries report them unavailable; the approval block then
    /// shows no policy or change line rather than one the app made up.
    func approvalTexts() async throws -> [String: FeatureApprovalText] {
        throw FeatureReadError.unavailable("approval summaries")
    }

    /// Workspaces without an event read report it unavailable; the inspector then shows the
    /// raw event it already has.
    func eventDetail(seq: Int) async throws -> FeatureEventDetail? {
        throw FeatureReadError.unavailable("event detail")
    }

    /// Workspaces without a replay engine report that replay is not available yet.
    func replay(run: String) async throws -> FeatureReplayResult {
        throw FeatureReadError.unavailable("replay")
    }
}
