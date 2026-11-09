import AryaCore
import AryaLedger
import Foundation

// Runs as projected from the ledger, and restart recovery (ARCHITECTURE.md "Durability"). A
// running run holds a lease for as long as its process drives it. On start, any run that is
// open in the ledger but whose lease nobody holds lost its process: it is recorded as
// `run.failed` with reason `interrupted`. Pending approvals need no recovery; they are a
// projection and survive as they are.

/// One run as projected from the ledger.
public struct RunRecord: Sendable, Hashable, Codable {
    /// Where a run is, as the ledger says.
    public enum Status: String, Sendable, Hashable, Codable {
        /// Started, not yet finished or failed.
        case running
        /// `run.finished` recorded.
        case finished
        /// `run.failed` recorded.
        case failed
    }

    enum CodingKeys: String, CodingKey {
        case id, steward, parent, trigger, input, charterVersion, rehearsal, status, endStatus
        case failureReason, summary, startedAt, endedAt, costMicros, actions
    }

    /// Run id.
    public var id: RunID
    /// Steward.
    public var steward: StewardID
    /// Parent run, for crew children.
    public var parent: RunID?
    /// Trigger kind.
    public var trigger: String
    /// Input text.
    public var input: String
    /// Charter version (0 for a candidate under rehearsal).
    public var charterVersion: Int
    /// True for rehearsal runs.
    public var rehearsal: Bool
    /// Status.
    public var status: Status
    /// `completed` or `stopped`, once finished.
    public var endStatus: String?
    /// Failure reason, once failed.
    public var failureReason: String?
    /// Summary from the result.
    public var summary: String?
    /// Start time.
    public var startedAt: Timestamp
    /// End time.
    public var endedAt: Timestamp?
    /// Cost in micro-dollars.
    public var costMicros: Int64
    /// Proposed actions.
    public var actions: Int
}

/// Folds run events into records.
public struct RunBook: RuntimeBook {
    /// Records by id.
    public private(set) var records: [RunID: RunRecord] = [:]
    private var order: [RunID] = []

    public static let cacheName = "runtime.runs.v1"

    enum CodingKeys: String, CodingKey { case records, order }

    /// An empty book.
    public init() {}

    /// Builds a book from events in ledger order.
    public init(_ events: [RuntimeEvent]) throws {
        for event in events { try apply(event) }
    }

    /// Every run, oldest first.
    public var all: [RunRecord] { order.compactMap { records[$0] } }

    /// Runs that started and have not ended, oldest first.
    public var open: [RunRecord] { all.filter { $0.status == .running } }

    /// Applies one event; other types are ignored, and so is a second ending of a run.
    public mutating func apply(_ event: RuntimeEvent) throws {
        guard let id = event.draft.run else { return }
        switch event.type {
        case RunEventType.started:
            guard let steward = event.draft.steward, records[id] == nil else { return }
            let body = try Payload.decode(RunStarted.self, event.payload)
            order.append(id)
            records[id] = RunRecord(
                id: id, steward: steward, parent: body.parent, trigger: body.input.kind.rawValue,
                input: body.input.text, charterVersion: body.charterVersion,
                rehearsal: body.rehearsal != nil || body.input.kind == .case, status: .running,
                startedAt: event.at, costMicros: 0, actions: 0)
        case RunEventType.finished:
            guard var record = records[id], record.status == .running else { return }
            let body = try Payload.decode(RunFinished.self, event.payload)
            record.status = .finished
            record.endStatus = body.status.rawValue
            record.summary = body.summary
            record.endedAt = event.at
            record.costMicros = body.cost.costMicros
            record.actions = body.counts.actions
            records[id] = record
        case RunEventType.failed:
            guard var record = records[id], record.status == .running else { return }
            let body = try Payload.decode(RunFailed.self, event.payload)
            record.status = .failed
            record.failureReason = body.reason
            record.endedAt = event.at
            record.costMicros = body.cost?.costMicros ?? 0
            records[id] = record
        default:
            return
        }
    }
}

/// A held claim that a process is driving a run.
public protocol RunLease: Sendable {
    /// Gives the claim up. Safe to call more than once.
    func release()
}

/// Claims on running runs, visible to every process that shares them.
public protocol RunLeases: Sendable {
    /// Claims `run` for this process.
    func acquire(_ run: RunID) throws -> any RunLease
    /// True when some live process holds the claim on `run`.
    func isHeld(_ run: RunID) -> Bool
}

/// Leases inside one process, for tests.
public final class MemoryRunLeases: RunLeases, @unchecked Sendable {
    private let lock = NSLock()
    private var held: Set<RunID> = []

    /// Creates an empty set of leases.
    public init() {}

    public func acquire(_ run: RunID) throws -> any RunLease {
        lock.withLock { _ = held.insert(run) }
        return Lease { [weak self] in self?.lock.withLock { _ = self?.held.remove(run) } }
    }

    public func isHeld(_ run: RunID) -> Bool { lock.withLock { held.contains(run) } }

    private final class Lease: RunLease, @unchecked Sendable {
        private let onRelease: () -> Void
        private let lock = NSLock()
        private var released = false

        init(_ onRelease: @escaping () -> Void) { self.onRelease = onRelease }

        func release() {
            let first = lock.withLock {
                defer { released = true }
                return !released
            }
            if first { onRelease() }
        }
    }
}

/// Errors from file leases.
public enum RunLeaseError: Error, Equatable, Sendable {
    /// The lease file could not be opened or locked.
    case unavailable(String)
}

/// Leases as `flock`ed files `<directory>/<run>.lock`. The kernel drops a lock when its
/// process dies, so a crashed run's lease is free without any cleanup.
public final class FileRunLeases: RunLeases, @unchecked Sendable {
    private let directory: URL

    /// Uses (and creates) `directory`, for example `<home>/cache/runs`.
    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
    }

    public func acquire(_ run: RunID) throws -> any RunLease {
        let fd = open(path(run), O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw RunLeaseError.unavailable("open \(run)") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw RunLeaseError.unavailable("\(run) is held")
        }
        return FileLease(fd: fd)
    }

    public func isHeld(_ run: RunID) -> Bool {
        let fd = open(path(run), O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return true }
        flock(fd, LOCK_UN)
        return false
    }

    private func path(_ run: RunID) -> String {
        directory.appendingPathComponent("\(run.rawValue).lock").path
    }

    private final class FileLease: RunLease, @unchecked Sendable {
        private let lock = NSLock()
        private var fd: Int32?

        init(fd: Int32) { self.fd = fd }

        func release() {
            lock.withLock {
                guard let open = fd else { return }
                flock(open, LOCK_UN)
                close(open)
                fd = nil
            }
        }

        deinit { release() }
    }
}

/// Fails runs whose process is gone.
public struct RunRecovery: Sendable {
    private let sink: any EventSink
    private let leases: any RunLeases

    /// Creates a recovery over a sink and the leases runs hold.
    public init(sink: any EventSink, leases: any RunLeases) {
        self.sink = sink
        self.leases = leases
    }

    /// Records `run.failed` with reason `interrupted` for every open run nobody holds, oldest
    /// first, and returns those runs.
    @discardableResult
    public func recover() async throws -> [RunRecord] {
        let open = try await sink.book(RunBook.self).open
        var interrupted: [RunRecord] = []
        for record in open where !leases.isHeld(record.id) {
            let payload = RunFailed(
                reason: RunFailureReason.interrupted.rawValue, detail: "its process is gone")
            _ = try await sink.append(
                RuntimeEventDraft(
                    type: RunEventType.failed, steward: record.steward, run: record.id,
                    actor: .system, payload: try Payload.encode(payload)))
            interrupted.append(record)
        }
        return interrupted
    }
}
