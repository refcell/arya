import Foundation

/// What the diff pane shows for a pair of routine versions.
enum RoutineDiffState: Hashable, Sendable {
    case loading
    case diff(String)
    case identical
    case missing(version: String)
    case failed(String)
}

/// Loads two routine versions from the workspace and diffs them.
enum RoutineDiffLoader {
    static func load(
        _ workspace: any FeatureWorkspace, item: RoutineItem, old: String, new: String
    ) async -> RoutineDiffState {
        let steward = item.steward ?? ""
        do {
            guard
                let before = try await workspace.routineContent(
                    steward: steward, name: item.name, version: old)
            else { return .missing(version: old) }
            guard
                let after = try await workspace.routineContent(
                    steward: steward, name: item.name, version: new)
            else { return .missing(version: new) }
            let diff = LineDiff.unified(
                old: before, new: after,
                oldLabel: "\(item.name) \(RoutinesText.shortVersion(old))",
                newLabel: "\(item.name) \(RoutinesText.shortVersion(new))")
            return diff.isEmpty ? .identical : .diff(diff)
        } catch {
            return .failed(FeatureStore.describe(error))
        }
    }
}
