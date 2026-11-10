import AryaCore
import Foundation

/// The outcome of `LedgerStore.compact(through:)`.
public struct CompactionResult: Hashable, Sendable {
    /// Segment files moved to `archive/`, oldest first; empty when nothing was covered.
    public var archived: [String]
    /// The first live `seq` afterwards.
    public var firstSeq: Int64
    /// The `seq` of the checkpoint that anchors the live ledger.
    public var checkpoint: Int64
}

/// Why compaction refused to run. Nothing is moved when it throws.
public enum CompactionError: Error, Hashable, Sendable {
    /// `verify` failed; the headline of its report.
    case ledgerNotVerified(String)
    /// No trusted checkpoint has `through` at or after this `seq`.
    case noCheckpoint(Int64)
    /// `archive/` already holds a file with this name.
    case archiveConflict(String)
}

extension LedgerStore {
    /// `home/archive`.
    public var archiveDirectory: URL { home.appendingPathComponent("archive", isDirectory: true) }

    /// Moves the closed segments wholly at or before `through` into `archive/`, never deleting
    /// anything. Needs a clean `verify` and a trusted checkpoint with `through` at or after the
    /// requested `seq`; the cut falls at the end of the last segment that checkpoint lists
    /// at or before `through`, so the checkpoint anchors the live ledger afterwards. Runs
    /// under the append lock; a reader scanning at that moment may see a segment vanish and
    /// should retry.
    @discardableResult
    public func compact(through: Int64) throws -> CompactionResult {
        try exclusive {
            let verdict = try LedgerVerifier(home: home).verify()
            guard verdict.ok else {
                throw CompactionError.ledgerNotVerified(verdict.report.headline)
            }
            let reader = LedgerReader(home: home, archive: false)
            var chosen: (seq: Int64, value: SystemCheckpoint)?
            try reader.forEach(LedgerFilter(types: [.systemCheckpoint])) { event in
                let value = try event.payload(as: SystemCheckpoint.self)
                if value.through >= through { chosen = (event.seq, value) }
            }
            guard let chosen else { throw CompactionError.noCheckpoint(through) }
            let listed = Dictionary(
                chosen.value.segments.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            var moving: [Segment] = []
            for segment in try segments().dropLast() {
                guard let entry = listed[segment.name], entry.last <= through else { break }
                moving.append(segment)
            }
            try move(moving)
            let first = try segments().first.flatMap { try reader.firstEvent(of: $0) }
            return CompactionResult(
                archived: moving.map(\.name), firstSeq: first?.seq ?? 1, checkpoint: chosen.seq)
        }
    }

    private func move(_ moving: [Segment]) throws {
        guard !moving.isEmpty else { return }
        let fileManager = FileManager.default
        for segment in moving
        where fileManager.fileExists(
            atPath: archiveDirectory.appendingPathComponent(segment.name).path)
        {
            throw CompactionError.archiveConflict(segment.name)
        }
        try FileIO.makeDirectory(archiveDirectory)
        // Oldest first, so an interruption leaves a live ledger that still starts on a
        // segment boundary the checkpoint lists.
        for segment in moving {
            let target = archiveDirectory.appendingPathComponent(segment.name)
            let result = segment.url.withUnsafeFileSystemRepresentation { from in
                target.withUnsafeFileSystemRepresentation { rename(from!, $0!) }
            }
            if result != 0 {
                throw LedgerIOError(op: "rename", path: segment.name, code: errno)
            }
        }
        try FileIO.syncDirectory(archiveDirectory)
        try FileIO.syncDirectory(directory)
    }
}

/// The result of `LedgerVerifier.verifyArchive()`: archived segments re-hashed against the
/// anchoring checkpoint's list, and the last archived line linked to the first live one.
public struct ArchiveVerification: Hashable, Sendable {
    /// Archived segment files that matched, oldest first.
    public var checked: [String]
    public var failure: ArchiveProblem?

    public var ok: Bool { failure == nil }

    /// One line: `archive ok: …` or `archive broken: …`.
    public var headline: String {
        let files = "\(checked.count) archived \(checked.count == 1 ? "segment" : "segments")"
        guard let failure else { return "archive ok: \(files) match the checkpoint" }
        return "archive broken: \(failure) (\(files) matched before it)"
    }
}

/// Why the archive does not match.
public enum ArchiveProblem: Hashable, Sendable, CustomStringConvertible {
    /// The live ledger starts at `seq` 1 or has no anchoring checkpoint.
    case nothingAnchored
    case missing(String)
    case digestMismatch(String)
    /// The last archived event's hash is not the first live event's `prev`.
    case linkMismatch

    public var description: String {
        switch self {
        case .nothingAnchored: return "no anchoring checkpoint names archived segments"
        case .missing(let name): return "\(name) is missing from archive/"
        case .digestMismatch(let name): return "\(name) does not match its checkpoint digest"
        case .linkMismatch: return "the last archived event does not link to the first live one"
        }
    }
}

extension LedgerVerifier {
    /// Re-hashes every archived segment the anchoring checkpoint lists before the first live
    /// event, and checks that the newest one ends in the first live event's `prev`. Run it
    /// after `verify()`, which checks the checkpoint itself.
    public func verifyArchive() throws -> ArchiveVerification {
        let home = reader.directory.deletingLastPathComponent()
        guard let firstSegment = try reader.existingSegments().first,
            let first = try reader.firstEvent(of: firstSegment), first.seq > 1
        else { return ArchiveVerification(checked: [], failure: .nothingAnchored) }
        var anchor: SystemCheckpoint?
        try reader.forEach(LedgerFilter(types: [.systemCheckpoint])) { event in
            guard anchor == nil, let value = try? event.payload(as: SystemCheckpoint.self),
                value.anchors(firstSeq: first.seq)
            else { return }
            anchor = value
        }
        guard let anchor else {
            return ArchiveVerification(checked: [], failure: .nothingAnchored)
        }
        let archive = home.appendingPathComponent("archive", isDirectory: true)
        var checked: [String] = []
        var newest: Segment?
        for entry in anchor.segments where entry.last < first.seq {
            let segment = Segment(
                number: Int(entry.name.dropLast(6)) ?? 0,
                url: archive.appendingPathComponent(entry.name))
            guard FileManager.default.fileExists(atPath: segment.url.path) else {
                return ArchiveVerification(checked: checked, failure: .missing(entry.name))
            }
            guard try reader.sha256(of: segment) == entry.sha256 else {
                return ArchiveVerification(checked: checked, failure: .digestMismatch(entry.name))
            }
            checked.append(entry.name)
            newest = segment
        }
        guard let newest, try reader.lastEvent(of: newest)?.hash == first.prev else {
            return ArchiveVerification(checked: checked, failure: .linkMismatch)
        }
        return ArchiveVerification(checked: checked, failure: nil)
    }
}
