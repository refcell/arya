import Foundation

/// A write the app asks the workspace to record. Each one becomes ledger events attributed to
/// the local user; views never append raw events themselves.
enum FeatureWrite: Hashable, Sendable {
    case approve(approval: String)
    case deny(approval: String, reason: String)
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
    /// Yields once whenever new events may be available.
    func changes() -> AsyncStream<Void>
}

/// Errors from feature writes.
enum FeatureWriteError: Error, Hashable, Sendable {
    case unknownApproval(String)
    case alreadyDecided(String)
}
