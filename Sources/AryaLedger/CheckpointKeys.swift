import AryaCore
import CryptoKit
import Foundation

/// A checkpoint signing key held on this machine.
public struct CheckpointSigner: Sendable {
    public let privateKey: Curve25519.Signing.PrivateKey
    public var publicKey: Curve25519.Signing.PublicKey { privateKey.publicKey }
    /// `key_` + the first 16 hex digits of the SHA-256 of the raw public key.
    public var id: String { CheckpointKeys.id(of: publicKey) }

    public init(_ privateKey: Curve25519.Signing.PrivateKey) { self.privateKey = privateKey }

    /// Base64 Ed25519 signature over `bytes`.
    public func sign(_ bytes: [UInt8]) throws -> String {
        try privateKey.signature(for: Data(bytes)).base64EncodedString()
    }
}

/// Key storage for signed checkpoints (ARCHITECTURE.md, "Signed checkpoints and compaction").
///
/// The private key lives at `keys/checkpoint.key` (mode 0600, written atomically) and never
/// on the ledger; its public half is recorded once by `system.key.added`. Key material never
/// comes from `Ambient`, whose readings are recorded in the ledger: new keys come from
/// CryptoKit's system generator unless the caller passes one (tests pass fixed keys).
public struct CheckpointKeys: Sendable {
    public let directory: URL

    public init(home: URL) {
        directory = home.appendingPathComponent("keys", isDirectory: true)
    }

    /// `keys/checkpoint.key`.
    public var url: URL { directory.appendingPathComponent("checkpoint.key") }

    /// The stored signer, or nil when there is no key file. A file that does not parse throws
    /// `CheckpointKeyError.unreadable`.
    public func load() throws -> CheckpointSigner? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CheckpointKeyError.unreadable
        }
        guard case .object(let fields)? = try? JSONParser.parse(Array(data)),
            fields["v"] == 1, fields["algorithm"] == "ed25519",
            case .string(let encoded)? = fields["privateKey"],
            let raw = Data(base64Encoded: encoded),
            let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        else { throw CheckpointKeyError.unreadable }
        return CheckpointSigner(key)
    }

    /// Returns the stored signer, creating the key file and recording `system.key.added`
    /// when this home has none. Recording is skipped when the key is already on the ledger;
    /// a stored key the ledger does not know, while it knows others, throws `notRecorded`.
    public func ensure(
        store: LedgerStore, generate: () -> Curve25519.Signing.PrivateKey = { .init() }
    ) throws -> CheckpointSigner {
        let signer = try load() ?? write(CheckpointSigner(generate()))
        let ring = try KeyRing.read(LedgerReader(home: store.home, archive: false))
        if ring.keys[signer.id] == nil {
            // A second unsigned key would not be trusted; rotation must sign it.
            guard ring.keys.isEmpty else { throw CheckpointKeyError.notRecorded }
            try store.append(
                EventDraft(
                    SystemKeyAdded(
                        key: signer.id,
                        publicKey: signer.publicKey.rawRepresentation
                            .base64EncodedString()), actor: .system))
        }
        return signer
    }

    /// Replaces the stored key with a new one and records a `system.key.added` signed by the
    /// old key. The old key file moves to `keys/retired/<id>.key`; nothing is deleted.
    @discardableResult
    public func rotate(
        store: LedgerStore, generate: () -> Curve25519.Signing.PrivateKey = { .init() }
    ) throws -> CheckpointSigner {
        guard let old = try load() else { throw CheckpointKeyError.noKey }
        let new = CheckpointSigner(generate())
        var payload = SystemKeyAdded(
            key: new.id, publicKey: new.publicKey.rawRepresentation.base64EncodedString(),
            replaces: old.id)
        payload.signature = try old.sign(CanonicalJSON.bytes(payload))
        let retired = directory.appendingPathComponent("retired", isDirectory: true)
        try FileIO.makeDirectory(retired)
        try FileIO.atomicWrite(
            try Data(contentsOf: url), to: retired.appendingPathComponent("\(old.id).key"))
        try write(new)
        try store.append(EventDraft(payload, actor: .system))
        return new
    }

    /// `key_` + the first 16 hex digits of the SHA-256 of the raw public key.
    public static func id(of key: Curve25519.Signing.PublicKey) -> String {
        "key_" + LedgerLine.hexSHA256(key.rawRepresentation).prefix(16)
    }

    @discardableResult
    private func write(_ signer: CheckpointSigner) throws -> CheckpointSigner {
        let file: JSONValue = [
            "v": 1, "algorithm": "ed25519", "key": .string(signer.id),
            "privateKey": .string(signer.privateKey.rawRepresentation.base64EncodedString()),
        ]
        var bytes = [UInt8]()
        try CanonicalJSON.write(file, into: &bytes)
        try FileIO.makeDirectory(directory)
        // `mkstemp` creates the temp file with mode 0600, and `rename` keeps it.
        try FileIO.atomicWrite(Data(bytes + [0x0A]), to: url)
        return signer
    }
}

/// The checkpoint keys recorded on the ledger, folded from `system.key.added`. The first key
/// must stand alone; every later key must name a recorded key in `replaces` and carry its
/// valid signature. Events that break these rules are listed in `rejected`, not trusted.
public struct KeyRing: LedgerProjection, Hashable {
    /// Trusted keys by id.
    public private(set) var keys: [String: Data] = [:]
    /// The newest trusted key.
    public private(set) var current: String?
    /// `seq`s of `system.key.added` events that were not trusted.
    public private(set) var rejected: [Int64] = []

    public init() {}

    /// The public key for `id`, if trusted.
    public func publicKey(_ id: String) -> Curve25519.Signing.PublicKey? {
        keys[id].flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
    }

    public mutating func apply(_ event: Event) throws {
        guard event.type == .systemKeyAdded else { return }
        guard let payload = try? event.payload(as: SystemKeyAdded.self), trusts(payload) else {
            rejected.append(event.seq)
            return
        }
        keys[payload.key] = Data(base64Encoded: payload.publicKey)
        current = payload.key
    }

    /// Trusts keys carried by an anchoring checkpoint (id to base64 public key). Entries
    /// whose id does not match their key are ignored.
    mutating func trust(_ carried: [String: String]) {
        for (id, encoded) in carried.sorted(by: { $0.key < $1.key }) where keys[id] == nil {
            guard let raw = Data(base64Encoded: encoded),
                let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
                CheckpointKeys.id(of: key) == id
            else { continue }
            keys[id] = raw
            current = current ?? id
        }
    }

    /// The trusted keys as checkpoint `keys`: id to base64 public key.
    public var carried: [String: String] { keys.mapValues { $0.base64EncodedString() } }

    /// Folds every `system.key.added` in the ledger (a typed, sieved read).
    public static func read(_ reader: LedgerReader) throws -> KeyRing {
        var ring = KeyRing()
        try reader.forEach(LedgerFilter(types: [.systemKeyAdded])) { try ring.apply($0) }
        return ring
    }

    private func trusts(_ payload: SystemKeyAdded) -> Bool {
        guard payload.v == 1, payload.algorithm == "ed25519", keys[payload.key] == nil,
            let raw = Data(base64Encoded: payload.publicKey),
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
            CheckpointKeys.id(of: key) == payload.key
        else { return false }
        guard let replaces = payload.replaces else {
            return keys.isEmpty && payload.signature == nil
        }
        guard let signer = publicKey(replaces), let encoded = payload.signature,
            let signature = Data(base64Encoded: encoded)
        else { return false }
        var unsigned = payload
        unsigned.signature = nil
        guard let bytes = try? CanonicalJSON.bytes(unsigned) else { return false }
        return signer.isValidSignature(signature, for: Data(bytes))
    }
}

/// Checkpoint key failures.
public enum CheckpointKeyError: Error, Hashable, Sendable {
    /// `keys/checkpoint.key` exists but is not a version-1 Ed25519 key file.
    case unreadable
    /// A rotation was asked for with no stored key.
    case noKey
    /// The stored key is not on a ledger that already trusts other keys.
    case notRecorded
}
