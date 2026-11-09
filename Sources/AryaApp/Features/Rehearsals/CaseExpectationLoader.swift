import Foundation

/// The expected side of a case review.
enum ExpectationState: Hashable, Sendable {
    case loading
    case loaded(CaseOutcome, corrected: Bool)
    case missing
    case failed(String)
}

/// Finds a case's expected result: the latest correction's, else the casebook's.
enum CaseExpectationLoader {
    static func load(
        _ workspace: any FeatureWorkspace, casebook: String, result: CaseResult
    ) async -> ExpectationState {
        if let corrected = result.correctedExpected {
            return .loaded(CaseOutcome.expected(corrected), corrected: true)
        }
        do {
            guard let json = try await workspace.caseExpected(casebook: casebook, caseID: result.id)
            else { return .missing }
            return .loaded(CaseOutcome.expected(json), corrected: false)
        } catch {
            return .failed(FeatureStore.describe(error))
        }
    }
}
