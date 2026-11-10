import Arya
import Foundation

/// A write the app asks the workspace to record. Each one becomes ledger events attributed to
/// the local user; views never append raw events themselves.
enum FeatureWrite: Hashable, Sendable {
    case approve(approval: String)
    /// Denies an approval; `reason` is recorded as the decision's `note`.
    case deny(approval: String, reason: String)
    case acceptProposal(String)
    case rejectProposal(String, reason: String)
    /// Accepts a proposal whose gate failed; recorded as `proposal.overridden`.
    case overrideProposal(String, reason: String)
    /// Hides a memory note from future runs (`memory.retracted`).
    case retractMemory(note: String, reason: String)
    /// Records a person's correction of a rehearsed case (`case.corrected`), optionally with a
    /// new expected result, and keeps it as a memory note attributed to the person.
    case correctCase(CaseCorrection)
    /// A person's message to a steward through the inbox (decision 0039): `by` is a person
    /// binding id ("Message as Sam" on People), or `local` for the person at this home.
    case message(steward: String, text: String, intent: MessageIntent, by: String = "local")
    /// Teaches a steward from a live run: the run becomes a case expecting `choice` as its
    /// first decision, with an optional memory note (`correct(run:expected:note:by:)`).
    case correctRun(steward: String, run: String, choice: String, note: String)
    /// Records a person's review of a case in the review queue (`case.reviewed`): `agree` or
    /// `skip`; corrections use `correctCase`.
    case reviewCase(steward: String, caseID: String, verdict: String)
    /// Marks a steward ready for live triggers after reviewing a rehearsal (`steward.ready`).
    case markReady(steward: String, charterVersion: Int, rehearsal: String?)
    /// Proposes a new charter version (`proposal.created`); it goes live only through a gate.
    case proposeCharter(CharterProposal)
    /// Starts a manual run with the person's input (`run.started`, trigger `manual`).
    case startRun(steward: String, input: String)
    /// Rehearses the live charter on a casebook version (nil: the steward's newest).
    case rehearse(steward: String, casebook: String?)
    /// Answers a question; recorded as `approval.granted` with the answer as its `note`.
    case answer(approval: String, text: String)
    /// Sends a steward's periodic report now to the people its charter names (`report.sent`).
    case sendReport(steward: String)
    /// Creates a steward from the New steward flow (`steward.created`, version 1).
    case createSteward(StewardDraft)
}

/// What the workspace says about a pending approval: why policy held it, in a sentence (a
/// charter rule's note, a generated sentence, or an autonomy explanation), and what the action
/// would change ("label: none → billing").
struct FeatureApprovalText: Hashable, Sendable {
    var policy: String?
    var change: String?
}

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

/// The result of checking the ledger's hash chain.
enum FeatureVerifyResult: Hashable, Sendable {
    case intact(events: Int)
    case broken(seq: Int, reason: String)
}

/// What the feature views need from a workspace. A local seam so the views build and test
/// before the `Arya` facade lands; the facade will conform to it (or replace it) later.
protocol FeatureWorkspace: Sendable {
    /// Every event in ledger order.
    func events() async throws -> [FeatureEvent]
    /// Records a write from the local user and returns the events it appended.
    @discardableResult
    func record(_ write: FeatureWrite) async throws -> [FeatureEvent]
    /// Checks the ledger's hash chain.
    func verify() async throws -> FeatureVerifyResult
    /// The body of one routine version (a content-addressed blob), or nil if it is missing.
    func routineContent(steward: String, name: String, version: String) async throws -> String?
    /// The expected result of one case in a casebook version, or nil if it is missing.
    func caseExpected(casebook: String, caseID: String) async throws -> FeatureJSON?
    /// Replays a finished run and reports the first difference from the recording.
    func replay(run: String) async throws -> FeatureReplayResult
    /// The workspace's words for each pending approval, by approval id.
    func approvalTexts() async throws -> [String: FeatureApprovalText]
    /// Yields each time a live run's ledger grows, and finishes when the run ends.
    func observeRun(_ run: String) -> AsyncStream<Void>
    /// What `run` would have done under a proposal's charter, in one line.
    func whatIf(run: String, proposal: String) async throws -> String
    /// The Improve screen's sentences for one steward, written by the workspace.
    func improveSummary(steward: String) async throws -> FeatureImproveSummary
    /// The review queue for one steward, or nil when it has no casebook.
    func reviewQueue(steward: String) async throws -> FeatureReviewQueue?
    /// One event's inspector detail (hash chain, run position, readable payload), or nil.
    func eventDetail(seq: Int) async throws -> FeatureEventDetail?
    /// The Knowledge screen for one steward, written by the workspace.
    func knowledge(steward: String) async throws -> FeatureKnowledge
    /// A charter proposal backtested against the live charter, for Improve.
    func liveReadiness(proposal: String) async throws -> FeatureLiveReadiness
    /// One person's conversation with a steward, oldest first (`Workspace.conversation`).
    func conversation(steward: String, person: String) async throws -> [FeatureConversationEntry]
    /// Yields once whenever new events may be available.
    func changes() -> AsyncStream<Void>
}

/// One message in a person's thread: theirs (inbound) or the steward's delivery (outbound).
struct FeatureConversationEntry: Hashable, Sendable {
    var seq: Int
    var inbound: Bool
    /// `ask`, `correct`, or `handoff`, for inbound messages.
    var intent: String?
    var text: String?
    /// The run that sent an outbound entry.
    var run: String?
}

extension FeatureWorkspace {
    /// Workspaces without a ledger watch never yield; the run shows as of its last reload.
    func observeRun(_ run: String) -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }

    /// Workspaces without a blob read report that routine bodies are not available yet.
    func routineContent(steward: String, name: String, version: String) async throws -> String? {
        throw FeatureReadError.unavailable("routine bodies")
    }

    /// Workspaces without a casebook read report that expected results are not available yet.
    func caseExpected(casebook: String, caseID: String) async throws -> FeatureJSON? {
        throw FeatureReadError.unavailable("expected results")
    }

    /// Workspaces without approval summaries report them unavailable; the approval block then
    /// shows no policy or change line rather than one the app made up.
    func approvalTexts() async throws -> [String: FeatureApprovalText] {
        throw FeatureReadError.unavailable("approval summaries")
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

    /// Workspaces without a conversation read report it unavailable; People then folds the
    /// ledger itself.
    func conversation(steward: String, person: String) async throws -> [FeatureConversationEntry] {
        throw FeatureReadError.unavailable("conversation")
    }

    /// Workspaces without a Knowledge read report it unavailable.
    func knowledge(steward: String) async throws -> FeatureKnowledge {
        throw FeatureReadError.unavailable("knowledge")
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

/// Errors from feature reads.
enum FeatureReadError: Error, Hashable, Sendable {
    /// The workspace cannot provide this yet.
    case unavailable(String)
}

/// Errors from feature writes.
enum FeatureWriteError: Error, Hashable, Sendable {
    case unknownApproval(String)
    case alreadyDecided(String)
    case unknownProposal(String)
    case proposalClosed(String)
    case gateNotPassed(String)
    case gatePassed(String)
    case unknownNote(String)
    case alreadyRetracted(String)
    case correctionEmpty
    case answerEmpty
    case staleCharter(live: Int)
}
