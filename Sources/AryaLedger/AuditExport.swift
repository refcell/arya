import AryaCore
import CryptoKit
import Foundation

// Signed audit export (governance (G5)): one steward's ledger slice as it is on disk, the
// key events that make the signer checkable, optionally the opened payloads of sealed lines,
// and a manifest signed with the home's checkpoint key. Anyone can check the bundle without
// the home: every line carries its own hash, the files' digests are in the manifest, and the
// signer's key is trusted through the bundled `system.key.added` lines.

/// `manifest.json` of an audit export: canonical JSON, signed without its `signature`.
public struct AuditManifest: Codable, Hashable, Sendable {
    public var v: Int
    /// The steward the slice covers; nil for the whole ledger.
    public var steward: String?
    /// Events in `events.jsonl`, and their first and last `seq`.
    public var count: Int
    public var first: Int64?
    public var last: Int64?
    /// The ledger's head when exported: the slice is everything up to here.
    public var head: Int64
    public var headHash: String
    /// SHA-256 of each file, lowercase hex.
    public var events: String
    public var keys: String
    /// `payloads.jsonl`, present when sealed payloads were opened for the reader.
    public var payloads: String?
    /// Lines in `events.jsonl` whose payload is sealed.
    public var sealed: Int
    /// The signer's key id and base64 Ed25519 public key.
    public var key: String
    public var publicKey: String
    public var signature: String?

    enum CodingKeys: String, CodingKey {
        case v, steward, count, first, last, head, headHash, events, keys, payloads, sealed, key
        case publicKey, signature
    }

    /// The bytes the signature covers: the canonical manifest without `signature`.
    public func signingBytes() throws -> [UInt8] {
        var unsigned = self
        unsigned.signature = nil
        return Array(try CanonicalJSON.encode(unsigned))
    }
}

/// `system.audit.exported`: a person exported a signed slice (actor: that person).
public struct SystemAuditExported: EventPayload {
    public static let type = EventType.systemAuditExported
    public var steward: StewardID?
    public var count: Int
    public var head: Int64
    /// SHA-256 of the signed manifest's canonical bytes.
    public var manifest: String
    /// Whether sealed payloads were opened into `payloads.jsonl`.
    public var revealed: Bool

    public init(steward: StewardID?, count: Int, head: Int64, manifest: String, revealed: Bool) {
        self.steward = steward
        self.count = count
        self.head = head
        self.manifest = manifest
        self.revealed = revealed
    }

    enum CodingKeys: String, CodingKey { case steward, count, head, manifest, revealed }
}

/// The result of checking an audit export.
public struct AuditCheck: Hashable, Sendable {
    public var manifest: AuditManifest?
    /// Problems found, in the order checked; empty when the bundle is intact.
    public var issues: [String]

    public var ok: Bool { manifest != nil && issues.isEmpty }
}

/// Writes and checks audit exports.
public enum AuditExport {
    public static let manifestFile = "manifest.json"
    public static let eventsFile = "events.jsonl"
    public static let keysFile = "keys.jsonl"
    public static let payloadsFile = "payloads.jsonl"

    /// Writes the slice of `steward` (the whole ledger when nil) into `directory`, which must
    /// not exist yet, signed by `signer`. With `reveal`, sealed payloads are opened into
    /// `payloads.jsonl` (needs the home key). Returns the signed manifest.
    public static func write(
        home: URL, steward: StewardID?, to directory: URL, signer: CheckpointSigner,
        reveal: Bool = false
    ) throws -> AuditManifest {
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw AuditExportError.exists
        }
        let reader = LedgerReader(home: home)
        let filter = LedgerFilter(steward: steward)
        var events: [UInt8] = []
        var keys: [UInt8] = []
        var payloads: [UInt8] = []
        var count = 0
        var sealed = 0
        var first: Int64?
        var last: Int64?
        var head: (Int64, String) = (0, Event.genesisHash)
        let keyFilter = LedgerFilter(types: [.systemKeyAdded])
        for segment in try reader.existingSegments() {
            try reader.scanLines(segment) { line, _, _ in
                let event = try LedgerLine.open(line)
                head = (event.seq, event.hash)
                if keyFilter.matches(event) { keys += line + [10] }
                guard filter.matches(event) else { return }
                events += line + [10]
                count += 1
                first = first ?? event.seq
                last = event.seq
                guard SealedPayload.isSealed(event) else { return }
                sealed += 1
                if reveal {
                    let opened = try HomeEncryption.opened(event, home: home)
                    let entry: JSONValue = ["seq": .int(event.seq), "payload": opened.payload]
                    payloads += Array(try CanonicalJSON.encode(entry)) + [10]
                }
            }
        }
        var manifest = AuditManifest(
            v: 1, steward: steward?.rawValue, count: count, first: first, last: last,
            head: head.0, headHash: head.1, events: LedgerLine.hexSHA256(events),
            keys: LedgerLine.hexSHA256(keys),
            payloads: reveal && sealed > 0 ? LedgerLine.hexSHA256(payloads) : nil,
            sealed: sealed, key: signer.id,
            publicKey: signer.publicKey.rawRepresentation.base64EncodedString())
        manifest.signature = try signer.sign(manifest.signingBytes())
        try FileIO.makeDirectory(directory)
        try FileIO.atomicWrite(Data(events), to: directory.appendingPathComponent(eventsFile))
        try FileIO.atomicWrite(Data(keys), to: directory.appendingPathComponent(keysFile))
        if manifest.payloads != nil {
            try FileIO.atomicWrite(
                Data(payloads), to: directory.appendingPathComponent(payloadsFile))
        }
        try FileIO.atomicWrite(
            try CanonicalJSON.encode(manifest), to: directory.appendingPathComponent(manifestFile))
        return manifest
    }

    /// Checks a bundle on its own: the manifest's signature by a key the bundled key events
    /// trust, each file's digest, every line's hash, `seq` order, and the steward.
    public static func verify(_ directory: URL) -> AuditCheck {
        func read(_ name: String) -> [UInt8]? {
            FileManager.default.contents(atPath: directory.appendingPathComponent(name).path)
                .map(Array.init)
        }
        guard let data = read(manifestFile),
            let manifest = try? JSONDecoder().decode(AuditManifest.self, from: Data(data)),
            manifest.v == 1
        else {
            return AuditCheck(manifest: nil, issues: ["manifest.json is missing or unreadable"])
        }
        var issues: [String] = []
        let events = read(eventsFile) ?? []
        let keys = read(keysFile) ?? []
        if LedgerLine.hexSHA256(events) != manifest.events {
            issues.append("events.jsonl does not match the manifest")
        }
        if LedgerLine.hexSHA256(keys) != manifest.keys {
            issues.append("keys.jsonl does not match the manifest")
        }
        if let digest = manifest.payloads, LedgerLine.hexSHA256(read(payloadsFile) ?? []) != digest
        {
            issues.append("payloads.jsonl does not match the manifest")
        }
        issues += checkSignature(manifest, keyLines: keys)
        issues += checkEvents(manifest, lines: events)
        return AuditCheck(manifest: manifest, issues: issues)
    }

    private static func checkSignature(_ manifest: AuditManifest, keyLines: [UInt8]) -> [String] {
        var ring = KeyRing()
        for line in keyLines.split(separator: 10) {
            guard let event = try? LedgerLine.open(line) else {
                return ["keys.jsonl has a line that fails its hash"]
            }
            try? ring.apply(event)
        }
        guard let trusted = ring.publicKey(manifest.key),
            trusted.rawRepresentation.base64EncodedString() == manifest.publicKey
        else { return ["the signing key \(manifest.key) is not trusted by keys.jsonl"] }
        guard let encoded = manifest.signature, let signature = Data(base64Encoded: encoded),
            let bytes = try? manifest.signingBytes(),
            trusted.isValidSignature(signature, for: Data(bytes))
        else { return ["the manifest signature does not verify"] }
        return []
    }

    private static func checkEvents(_ manifest: AuditManifest, lines: [UInt8]) -> [String] {
        var count = 0
        var previous: Int64 = 0
        var first: Int64?
        for (index, line) in lines.split(separator: 10).enumerated() {
            guard let event = try? LedgerLine.open(line) else {
                return ["events.jsonl line \(index + 1) fails its hash"]
            }
            if event.seq <= previous { return ["events.jsonl is out of order at seq \(event.seq)"] }
            if let steward = manifest.steward, event.steward?.rawValue != steward {
                return ["events.jsonl seq \(event.seq) belongs to another steward"]
            }
            if event.seq > manifest.head { return ["seq \(event.seq) is past the manifest head"] }
            previous = event.seq
            first = first ?? event.seq
            count += 1
        }
        guard count == manifest.count, first == manifest.first,
            (count == 0 ? nil : previous) == manifest.last
        else { return ["events.jsonl holds \(count) events; the manifest says \(manifest.count)"] }
        return []
    }
}

/// Audit export errors.
public enum AuditExportError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The target directory already exists; exports never overwrite.
    case exists
    /// `payloads.jsonl` holds a line that is not `{"payload", "seq"}`.
    case badPayloads

    public var description: String {
        switch self {
        case .exists: "the export folder already exists; choose a new one"
        case .badPayloads: "payloads.jsonl is not readable"
        }
    }
}

/// `system.audit.imported`: a steward was recreated from a checked audit export (actor: the
/// person). `head` and `manifest` name the export it came from; `key` is the key that signed it.
public struct SystemAuditImported: EventPayload {
    public static let type = EventType.systemAuditImported
    public var steward: StewardID
    public var count: Int
    public var head: Int64
    public var manifest: String
    public var key: String
    /// Memory notes carried over.
    public var notes: Int

    public init(
        steward: StewardID, count: Int, head: Int64, manifest: String, key: String, notes: Int
    ) {
        self.steward = steward
        self.count = count
        self.head = head
        self.manifest = manifest
        self.key = key
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey { case steward, count, head, manifest, key, notes }
}

extension AuditExport {
    /// The bundle's events in order, each sealed payload replaced by its opened copy from
    /// `payloads.jsonl` when the export revealed it. Call `verify` first; this only parses.
    public static func events(at directory: URL) throws -> [Event] {
        func lines(_ name: String) -> [ArraySlice<UInt8>] {
            let data = FileManager.default.contents(
                atPath: directory.appendingPathComponent(name).path)
            return data.map { Array($0).split(separator: 10) } ?? []
        }
        var opened: [Int64: JSONValue] = [:]
        for line in lines(payloadsFile) {
            let entry = try JSONParser.parse(Array(line))
            guard case .int(let seq)? = entry.objectValue?["seq"],
                let payload = entry.objectValue?["payload"]
            else { throw AuditExportError.badPayloads }
            opened[Int64(seq)] = payload
        }
        return try lines(eventsFile).map { line in
            var event = try LedgerLine.open(line)
            if let payload = opened[event.seq] { event.payload = payload }
            return event
        }
    }
}
