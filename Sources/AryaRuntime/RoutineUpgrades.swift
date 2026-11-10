import AryaCore
import AryaMemory

// Shared routines across stewards (decision 0062, on top of 0060). A routine version is its
// content hash, so a version adopted into another steward keeps the same id: one version,
// referenced by every steward that runs it. A steward follows the steward it first got its
// live version from (the one that proposed that version earliest). When the followed steward
// promotes a newer version, the follower has an upgrade available; taking it is a proposal of
// that version to the follower, gated by its own casebook like any adoption (0060), never a
// silent switch.

/// Where one routine name is used: each steward's live version and, for a follower, whom it
/// follows.
public struct RoutineUse: Sendable, Hashable {
    public var steward: StewardID
    public var name: String
    /// The live version, nil when the steward has it only proposed.
    public var live: String?
    /// The steward this one got its live version from, nil for the originator.
    public var follows: StewardID?
}

/// An upgrade a follower can take: the followed steward's newer live version.
public struct RoutineUpgrade: Sendable, Hashable {
    public var steward: StewardID
    public var name: String
    /// The follower's live version.
    public var from: String
    /// The followed steward's live version.
    public var to: String
    public var source: StewardID
    /// True when `to` is already proposed to the follower and waits for its gate.
    public var pending: Bool
}

/// Usage and upgrades over the routine library.
public enum RoutineUpgrades {
    /// Every steward in `stewards` that has proposed `name`, with its live version and whom it
    /// follows, in `stewards` order.
    public static func uses(
        of name: String, stewards: [StewardID], library: RoutineLibrary
    ) -> [RoutineUse] {
        stewards.compactMap { steward in
            guard library.names(steward: steward).contains(name) else { return nil }
            let live = library.live(steward: steward, name: name)
            return RoutineUse(
                steward: steward, name: name, live: live?.version,
                follows: live.flatMap {
                    origin(of: $0, name: name, stewards: stewards, library: library)
                })
        }
    }

    /// Upgrades available to `stewards` (one per follower and routine name), by steward then
    /// name.
    public static func available(stewards: [StewardID], library: RoutineLibrary)
        -> [RoutineUpgrade]
    {
        stewards.flatMap { steward in
            library.liveRoutines(steward: steward).compactMap { live in
                guard
                    let source = origin(
                        of: live, name: live.name, stewards: stewards, library: library),
                    let newer = library.live(steward: source, name: live.name),
                    newer.version != live.version,
                    let promoted = newer.promotedSeq, promoted > (live.promotedSeq ?? 0)
                else { return nil }
                let proposed = library.version(
                    steward: steward, name: live.name, version: newer.version)
                return RoutineUpgrade(
                    steward: steward, name: live.name, from: live.version, to: newer.version,
                    source: source, pending: proposed != nil && proposed?.promotedSeq == nil)
            }
        }
    }

    /// The steward that proposed `version` of `name` before `version.steward` did, earliest
    /// first, or nil when `version.steward` had it first.
    static func origin(
        of version: RoutineVersion, name: String, stewards: [StewardID], library: RoutineLibrary
    ) -> StewardID? {
        stewards.filter { $0 != version.steward }
            .compactMap { other in
                library.version(steward: other, name: name, version: version.version)
                    .map { (other, $0.proposedSeq) }
            }
            .filter { $0.1 < version.proposedSeq }
            .min { $0.1 < $1.1 }?.0
    }
}
