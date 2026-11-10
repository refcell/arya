import AryaCore
import Foundation

// Re-sealing history (governance (G4b)): events written before encryption was enabled keep
// their payloads in the clear, because the hash chain covers their bytes. Re-sealing rewrites
// the live ledger once into a sealed copy: the same events, ids, times, and `seq`s, with those
// payloads sealed, so every hash from the first sealed event on changes. Checkpoints are
// re-signed with the home's checkpoint key against the new heads and segment digests, the
// old-to-new hash map is kept as a blob, and `system.ledger.resealed` records the rewrite.
// The clear copy is removed: removing it is the point, and the person asks for it explicitly.

/// `system.ledger.resealed`: the live ledger was rewritten with earlier clear payloads sealed.
/// Actor: the person. `previousHead` is the head hash before the rewrite at `through`, and
/// `map` the blob holding `{"v":1,"map":[[seq, old, new], …]}` for every event whose hash
/// changed, so exports and checkpoints taken before can still be tied to this ledger.
public struct SystemLedgerResealed: EventPayload {
    public static let type = EventType.systemLedgerResealed
    public var through: Int64
    public var previousHead: String
    /// Payloads sealed by the rewrite, and checkpoints re-signed.
    public var sealed: Int
    public var checkpoints: Int
    public var map: String
    /// The checkpoint key that re-signed the checkpoints.
    public var key: String

    public init(
        through: Int64, previousHead: String, sealed: Int, checkpoints: Int, map: String,
        key: String
    ) {
        self.through = through
        self.previousHead = previousHead
        self.sealed = sealed
        self.checkpoints = checkpoints
        self.map = map
        self.key = key
    }

    enum CodingKeys: String, CodingKey {
        case through, previousHead, sealed, checkpoints, map, key
    }
}

/// Why history cannot be re-sealed. Nothing changes when it throws.
public enum ResealError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The home is not encrypted.
    case notEncrypted
    /// Segments were archived (retention or compaction); re-sealing covers a whole chain only.
    case compacted
    /// A checkpoint is signed by a key this home does not hold, so it cannot be re-signed.
    case foreignCheckpoint(String)
    /// `verify` failed before the rewrite.
    case notVerified(String)

    public var description: String {
        switch self {
        case .notEncrypted: "encryption is off; turn it on first"
        case .compacted: "archived segments cannot be re-sealed; only a whole live ledger can"
        case .foreignCheckpoint(let key):
            "a checkpoint is signed by \(key), which this home does not hold"
        case .notVerified(let headline): "the ledger does not verify: \(headline)"
        }
    }
}

/// Rewrites the live ledger with earlier clear payloads sealed.
public enum Reseal {
    /// Re-seals every clear payload that encryption would seal now (`SealedPayload.applies`)
    /// and records `system.ledger.resealed`. Returns nil, changing nothing, when no payload is
    /// in the clear. Runs under the append lock; a reader scanning at that moment may see the
    /// directory swap and should retry.
    @discardableResult
    public static func apply(store: LedgerStore, signer: CheckpointSigner, actor: Actor) throws
        -> SystemLedgerResealed?
    {
        guard let cipher = try HomeEncryption.sealing(store.home) else {
            throw ResealError.notEncrypted
        }
        let staging = store.home.appendingPathComponent("ledger.reseal", isDirectory: true)
        let outcome: Rewrite? = try store.exclusive {
            let verdict = try LedgerVerifier(home: store.home).verify()
            guard verdict.ok else { throw ResealError.notVerified(verdict.report.headline) }
            guard verdict.firstSeq == 1 else { throw ResealError.compacted }
            try? FileManager.default.removeItem(at: staging)
            var rewrite = Rewrite()
            try rewrite.write(store: store, into: staging, cipher: cipher, signer: signer)
            guard rewrite.sealed > 0 else {
                try? FileManager.default.removeItem(at: staging)
                return nil
            }
            try swap(staging, store.directory)
            try FileManager.default.removeItem(at: staging)
            try FileIO.syncDirectory(store.home)
            return rewrite
        }
        guard let outcome else { return nil }
        // Caches name the old hashes; they rebuild from the new chain on the next read.
        let caches = ProjectionCache(home: store.home)
        try? FileManager.default.removeItem(at: caches.directory)
        let map = try store.blobs.put(try CanonicalJSON.encode(outcome.mapValue))
        let event = SystemLedgerResealed(
            through: outcome.through, previousHead: outcome.previousHead, sealed: outcome.sealed,
            checkpoints: outcome.checkpoints, map: map, key: signer.id)
        try store.append(EventDraft(event, actor: actor))
        return event
    }

    /// Atomically exchanges two directories (macOS `RENAME_SWAP`).
    private static func swap(_ a: URL, _ b: URL) throws {
        let result = a.withUnsafeFileSystemRepresentation { from in
            b.withUnsafeFileSystemRepresentation { renamex_np(from!, $0!, UInt32(RENAME_SWAP)) }
        }
        if result != 0 { throw LedgerIOError(op: "rename", path: b.lastPathComponent, code: errno) }
    }

    /// The rewritten chain, built segment by segment into a staging directory.
    struct Rewrite {
        var sealed = 0
        var checkpoints = 0
        var through: Int64 = 0
        var previousHead = Event.genesisHash
        /// `seq` to the new hash, and old segment names to their new digests.
        var hashes: [Int64: String] = [:]
        var digests: [String: String] = [:]
        var changed: [(Int64, String, String)] = []

        var mapValue: JSONValue {
            [
                "v": 1,
                "map": .array(
                    changed.map { .array([.int($0.0), .string($0.1), .string($0.2)]) }),
            ]
        }

        mutating func write(
            store: LedgerStore, into staging: URL, cipher: HomeCipher, signer: CheckpointSigner
        ) throws {
            try FileIO.makeDirectory(staging)
            let reader = LedgerReader(home: store.home, archive: false)
            var prev = Event.genesisHash
            for segment in try reader.liveSegments() {
                var bytes: [UInt8] = []
                try reader.scanLines(segment) { line, _, _ in
                    let event = try LedgerLine.open(line)
                    var payload = event.payload
                    if SealedPayload.applies(to: event.type), !SealedPayload.isSealed(event) {
                        try LedgerLine.checkPayload(payload)
                        payload = try SealedPayload.seal(
                            payload, cipher: cipher,
                            context: SealedPayload.context(
                                id: event.id, seq: event.seq, type: event.type))
                        sealed += 1
                    } else if event.type == .systemCheckpoint {
                        payload = try resigned(event, signer: signer)
                    }
                    let draft = EventDraft(
                        type: event.type, actor: event.actor, steward: event.steward,
                        run: event.run, payload: payload)
                    let (written, out) = try LedgerLine.seal(
                        draft, seq: event.seq, prev: prev, id: event.id, at: event.at)
                    prev = written.hash
                    hashes[event.seq] = written.hash
                    if written.hash != event.hash {
                        changed.append((event.seq, event.hash, written.hash))
                    }
                    through = event.seq
                    previousHead = event.hash
                    bytes += out + [10]
                }
                let url = staging.appendingPathComponent(segment.name)
                try FileIO.atomicWrite(Data(bytes), to: url)
                digests[segment.name] = LedgerLine.hexSHA256(bytes)
            }
            try FileIO.syncDirectory(staging)
        }

        /// A checkpoint's payload against the rewritten chain, signed by `signer`.
        private mutating func resigned(_ event: Event, signer: CheckpointSigner) throws
            -> JSONValue
        {
            var checkpoint = try event.payload(as: SystemCheckpoint.self)
            guard checkpoint.key == signer.id else {
                throw ResealError.foreignCheckpoint(checkpoint.key)
            }
            guard let head = hashes[checkpoint.through] else {
                throw CheckpointError.outOfRange(checkpoint.through)
            }
            checkpoint.head = head
            checkpoint.segments = try checkpoint.segments.map { listed in
                guard let digest = digests[listed.name] else {
                    throw CheckpointError.outOfRange(listed.last)
                }
                var entry = listed
                entry.sha256 = digest
                return entry
            }
            checkpoint.signature = try signer.sign(checkpoint.signingBytes())
            checkpoints += 1
            return try CanonicalJSON.jsonValue(checkpoint)
        }
    }
}
