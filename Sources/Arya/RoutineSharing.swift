import AryaCore
import AryaRuntime
import Foundation

// Shared routines (runtime decision 0062): which stewards run a routine and which version, and
// the upgrades a steward can take from the steward it adopted the routine from. Taking one is
// an adoption of the newer version (decision 0060): a proposal gated by the steward's casebook.

/// One steward's use of a routine.
public struct RoutineUseSummary: Sendable, Hashable, Codable {
    public var steward: String
    public var name: String
    /// The live version, nil when only proposed.
    public var liveVersion: String?
    /// The steward it adopted the routine from, nil for the originator.
    public var follows: String?
}

/// A newer version a steward can take from the steward it follows.
public struct RoutineUpgradeSummary: Sendable, Hashable, Codable {
    public var steward: String
    public var name: String
    public var fromVersion: String
    public var toVersion: String
    public var source: String
    /// True when the newer version is already proposed and waits for the steward's gate.
    public var pending: Bool
}

extension Workspace {
    /// Every steward that has `name`, with its live version and whom it follows.
    public func routineUses(name: String) async throws -> [RoutineUseSummary] {
        let state = try facadeState()
        return RoutineUpgrades.uses(
            of: name, stewards: state.stewards.all.map(\.id), library: state.routines
        ).map {
            RoutineUseSummary(
                steward: $0.steward.rawValue, name: $0.name, liveVersion: $0.live,
                follows: $0.follows?.rawValue)
        }
    }

    /// Upgrades available to `steward`, or to every steward when nil.
    public func routineUpgrades(steward: String? = nil) async throws -> [RoutineUpgradeSummary] {
        var id: StewardID?
        if let steward { id = try await existing(steward).id }
        let state = try facadeState()
        return RoutineUpgrades.available(
            stewards: state.stewards.all.map(\.id), library: state.routines
        ).filter { id == nil || $0.steward == id }.map {
            RoutineUpgradeSummary(
                steward: $0.steward.rawValue, name: $0.name, fromVersion: $0.from,
                toVersion: $0.to, source: $0.source.rawValue, pending: $0.pending)
        }
    }

    /// Takes the upgrade of `name` available to `steward`: proposes the followed steward's
    /// newer version and runs `steward`'s routine gate, so it goes live only if the casebook
    /// still passes.
    public func upgradeRoutine(steward: String, name: String, by person: String = "local")
        async throws -> RoutineGateSummary
    {
        guard
            let upgrade = try await routineUpgrades(steward: steward).first(where: {
                $0.name == name
            })
        else {
            throw WorkspaceError.rejected("\(steward) has no upgrade for \(name)")
        }
        return try await adoptRoutine(
            name: name, version: upgrade.toVersion, from: upgrade.source, into: steward,
            by: person)
    }
}
