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
    /// Uses one steward's routine version in another (`adoptRoutine`): proposed there and run
    /// through that steward's routine gate, so it goes live only when its casebook passes.
    case adoptRoutine(name: String, version: String, from: String, into: String)
    /// Takes the routine upgrade available to `steward` (`upgradeRoutine`, decision 0062): the
    /// followed steward's newer version, proposed and gated there.
    case upgradeRoutine(steward: String, name: String)
}

/// The result of checking the ledger's hash chain.
enum FeatureVerifyResult: Hashable, Sendable {
    case intact(events: Int)
    case broken(seq: Int, reason: String)
}

/// What the feature views need from a workspace. A local seam so the views build and test
/// before the `Arya` facade lands; the facade will conform to it (or replace it) later.
/// The core reads and writes (app-shell) plus each lane's reads, one protocol and file per
/// lane: `FeatureRunReads` (+Run), `FeatureOutcomeReads` (+Outcome), `FeatureConnectReads`
/// (+Connect).
protocol FeatureWorkspace: FeatureRunReads, FeatureOutcomeReads, FeatureConnectReads {
    /// Every event in ledger order.
    func events() async throws -> [FeatureEvent]
    /// Records a write from the local user and returns the events it appended.
    @discardableResult
    func record(_ write: FeatureWrite) async throws -> [FeatureEvent]
    /// Checks the ledger's hash chain.
    func verify() async throws -> FeatureVerifyResult
    /// Example stewards to start a New steward from (app-shell, Templates).
    func templates() -> [StewardTemplate]
    /// The Knowledge screen for one steward, written by the workspace.
    func knowledge(steward: String) async throws -> FeatureKnowledge
    /// Yields once whenever new events may be available.
    func changes() -> AsyncStream<Void>
}

extension FeatureWorkspace {
    func templates() -> [StewardTemplate] { [] }

    /// Workspaces without a Knowledge read report it unavailable.
    func knowledge(steward: String) async throws -> FeatureKnowledge {
        throw FeatureReadError.unavailable("knowledge")
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
