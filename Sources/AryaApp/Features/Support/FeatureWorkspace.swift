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
    /// Marks a steward ready for live triggers after reviewing a rehearsal (`steward.ready`).
    case markReady(steward: String, charterVersion: Int, rehearsal: String?)
    /// Proposes a new charter version (`proposal.created`); it goes live only through a gate.
    case proposeCharter(CharterProposal)
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
    /// Yields once whenever new events may be available.
    func changes() -> AsyncStream<Void>
}

extension FeatureWorkspace {
    /// Workspaces without a blob read report that routine bodies are not available yet.
    func routineContent(steward: String, name: String, version: String) async throws -> String? {
        throw FeatureReadError.unavailable("routine bodies")
    }

    /// Workspaces without a casebook read report that expected results are not available yet.
    func caseExpected(casebook: String, caseID: String) async throws -> FeatureJSON? {
        throw FeatureReadError.unavailable("expected results")
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
    case staleCharter(live: Int)
}
