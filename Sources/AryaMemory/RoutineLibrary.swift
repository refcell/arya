import AryaCore
import Foundation

/// One proposed version of a routine, with its lifecycle in ledger `seq`s.
public struct RoutineVersion: Sendable, Equatable {
    public var steward: StewardID
    public var name: String
    public var version: String
    public var language: RoutineLanguage
    public var bytes: Int
    public var summary: String
    public var reason: String?
    public var run: RunID?
    public var proposedSeq: Int
    /// The last time this version was promoted, if ever.
    public var promotedSeq: Int?
    /// The proposal that promoted it, if recorded.
    public var proposal: ProposalID?
}

/// One step in a routine's history, for the app's version view.
public struct RoutineHistoryEntry: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case proposed
        case promoted
        case retired
    }

    public var seq: Int
    public var kind: Kind
    public var version: String
}

/// A `routine.*` event the library ignored because it contradicts the projection. Valid
/// writers never produce one; the app and `arya ledger verify` can surface them.
public struct RoutineAnomaly: Sendable, Equatable {
    public var seq: Int
    public var detail: String
}

/// Routines per steward projected from `routine.*` events: every proposed version, the live
/// version per name, and each name's history. Other event types are ignored.
public struct RoutineLibrary: Sendable, Equatable {
    private struct Key: Hashable, Sendable {
        var steward: StewardID
        var name: String
    }

    private var versions: [Key: [String: RoutineVersion]] = [:]
    private var live: [Key: String] = [:]
    private var histories: [Key: [RoutineHistoryEntry]] = [:]
    public private(set) var anomalies: [RoutineAnomaly] = []
    public private(set) var lastSeq = 0

    public init() {}

    public init(events: some Sequence<MemoryEventRecord>) throws(MemoryProjectionError) {
        for event in events { try apply(event) }
    }

    /// Applies one event in ledger order.
    public mutating func apply(_ event: MemoryEventRecord) throws(MemoryProjectionError) {
        lastSeq = max(lastSeq, event.seq)
        switch event.type {
        case RoutineEventType.proposed:
            let p: RoutineProposedPayload = try decode(event)
            propose(p, key: Key(steward: try steward(event), name: p.name), seq: event.seq)
        case RoutineEventType.promoted:
            let p: RoutinePromotedPayload = try decode(event)
            promote(p, key: Key(steward: try steward(event), name: p.name), seq: event.seq)
        case RoutineEventType.retired:
            let p: RoutineRetiredPayload = try decode(event)
            retire(p, key: Key(steward: try steward(event), name: p.name), seq: event.seq)
        default:
            return
        }
    }

    /// Records that the ledger reached `seq` without a relevant event.
    mutating func lastSeqFloor(_ seq: Int) {
        lastSeq = max(lastSeq, seq)
    }

    // MARK: Queries

    /// The live version of a routine, if any.
    public func live(steward: StewardID, name: String) -> RoutineVersion? {
        let key = Key(steward: steward, name: name)
        return live[key].flatMap { versions[key]?[$0] }
    }

    /// Every live routine of a steward, sorted by name.
    public func liveRoutines(steward: StewardID) -> [RoutineVersion] {
        live.keys.filter { $0.steward == steward }.map(\.name).sorted()
            .compactMap { live(steward: steward, name: $0) }
    }

    /// A specific version of a routine, live or not.
    public func version(steward: StewardID, name: String, version: String) -> RoutineVersion? {
        versions[Key(steward: steward, name: name)]?[version]
    }

    /// Every proposed version of a routine, oldest first.
    public func versions(steward: StewardID, name: String) -> [RoutineVersion] {
        (versions[Key(steward: steward, name: name)] ?? [:]).values
            .sorted { $0.proposedSeq < $1.proposedSeq }
    }

    /// Proposed versions that were never promoted, oldest first.
    public func pending(steward: StewardID) -> [RoutineVersion] {
        versions.filter { $0.key.steward == steward }.values.flatMap(\.values)
            .filter { $0.promotedSeq == nil }.sorted { $0.proposedSeq < $1.proposedSeq }
    }

    /// Every routine name a steward has proposed, sorted.
    public func names(steward: StewardID) -> [String] {
        versions.keys.filter { $0.steward == steward }.map(\.name).sorted()
    }

    /// A routine's history in ledger order.
    public func history(steward: StewardID, name: String) -> [RoutineHistoryEntry] {
        histories[Key(steward: steward, name: name)] ?? []
    }

    // MARK: Transitions

    private mutating func propose(_ p: RoutineProposedPayload, key: Key, seq: Int) {
        guard versions[key]?[p.version] == nil else {
            anomalies.append(.init(seq: seq, detail: "duplicate proposal of \(p.name)"))
            return
        }
        versions[key, default: [:]][p.version] = RoutineVersion(
            steward: key.steward, name: p.name, version: p.version, language: p.language,
            bytes: p.bytes, summary: p.summary, reason: p.reason, run: p.run,
            proposedSeq: seq)
        histories[key, default: []].append(.init(seq: seq, kind: .proposed, version: p.version))
    }

    private mutating func promote(_ p: RoutinePromotedPayload, key: Key, seq: Int) {
        guard versions[key]?[p.version] != nil else {
            anomalies.append(.init(seq: seq, detail: "promotion of unproposed \(p.name)"))
            return
        }
        versions[key]?[p.version]?.promotedSeq = seq
        versions[key]?[p.version]?.proposal = p.proposal
        live[key] = p.version
        histories[key, default: []].append(.init(seq: seq, kind: .promoted, version: p.version))
    }

    private mutating func retire(_ p: RoutineRetiredPayload, key: Key, seq: Int) {
        guard live[key] == p.version else {
            anomalies.append(.init(seq: seq, detail: "retirement of non-live \(p.name)"))
            return
        }
        live[key] = nil
        histories[key, default: []].append(.init(seq: seq, kind: .retired, version: p.version))
    }

    private func steward(_ event: MemoryEventRecord) throws(MemoryProjectionError) -> StewardID {
        guard let steward = event.steward else { throw .missingSteward(seq: event.seq) }
        return steward
    }

    private func decode<T: Decodable>(_ event: MemoryEventRecord) throws(MemoryProjectionError)
        -> T
    {
        do {
            return try CanonicalJSON.decode(T.self, from: event.payload)
        } catch {
            throw .invalidPayload(seq: event.seq, type: event.type)
        }
    }
}

/// Reasons routine content cannot be loaded.
public enum RoutineContentError: Error, Equatable, Sendable {
    case missingBlob(String)
    case corruptBlob(String)
    case unreadable(String)
}

extension RoutineSource {
    /// Stores the content in `store` and returns the `routine.proposed` payload to record.
    public func propose(
        into store: some RoutineBlobStore, reason: String? = nil,
        run: RunID? = nil
    ) throws -> RoutineProposedPayload {
        let key = try store.put(data)
        guard key == version else { throw RoutineContentError.corruptBlob(key) }
        return RoutineProposedPayload(source: self, reason: reason, run: run)
    }
}

extension RoutineVersion {
    /// Loads and checks this version's content: the blob's hash must equal `version`.
    public func content(from store: some RoutineBlobStore) throws(RoutineContentError)
        -> String
    {
        let data: Data?
        do {
            data = try store.getIfPresent(version)
        } catch let error as RoutineContentError {
            throw error
        } catch {
            throw .unreadable(version)
        }
        guard let data else { throw .missingBlob(version) }
        guard RoutineNaming.version(of: data) == version else { throw .corruptBlob(version) }
        guard let text = String(data: data, encoding: .utf8) else {
            throw .corruptBlob(version)
        }
        return text
    }
}
