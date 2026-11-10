import AryaCore
import Foundation

/// Saved projections in `home/cache/<name>.json`, so opening a large ledger does not refold it
/// from the start. Safe to delete: a missing, corrupt, or stale cache only costs a rebuild.
///
/// File format: `{"v":1,"name":…,"seq":…,"hash":…,"value":{…}}`, where `seq` and
/// `hash` name the last folded event. Writes are atomic (temp file and rename). In an
/// encrypted home files are sealed (`HomeEncryption`), and seeds keep the sealed bytes.
public struct ProjectionCache: Sendable {
    /// `home/cache`.
    public let directory: URL
    public let reader: LedgerReader

    public init(home: URL) {
        directory = home.appendingPathComponent("cache", isDirectory: true)
        reader = LedgerReader(home: home)
    }

    var home: URL { directory.deletingLastPathComponent() }

    /// The authenticated context of a sealed cache or seed file named `name`.
    static func context(_ name: String) -> String { "cache|" + name }

    /// A cache or seed file's plaintext, opened when sealed; nil when missing or unreadable.
    func plaintext(_ url: URL, name: String) -> Data? {
        guard let data = FileManager.default.contents(atPath: url.path),
            let plain = try? HomeEncryption.openFile(
                Array(data), home: home, context: Self.context(name))
        else { return nil }
        return Data(plain)
    }

    /// The saved projection, or nil if there is none or it cannot be read.
    public func load<P: LedgerProjection & Codable>(_ type: P.Type, name: String) -> Projected<P>? {
        guard Self.isValidName(name),
            let data = plaintext(url(name), name: name),
            let file = try? JSONDecoder().decode(CacheFile<P>.self, from: data),
            file.v == 1, file.name == name, file.seq >= 0, BlobStore.isValidKey(file.hash)
        else { return nil }
        return Projected(value: file.value, seq: file.seq, hash: file.hash)
    }

    /// Saves `projected` under `name`.
    public func save<P: LedgerProjection & Codable>(_ projected: Projected<P>, name: String) throws
    {
        guard Self.isValidName(name) else { throw ProjectionCacheError.invalidName(name) }
        let file = CacheFile(
            v: 1, name: name, seq: projected.seq, hash: projected.hash, value: projected.value)
        try FileIO.makeDirectory(directory)
        try HomeEncryption.write(
            Array(try CanonicalJSON.encode(file)), to: url(name), home: home,
            context: Self.context(name))
    }

    /// Loads the cache (or starts empty), catches up with the ledger, saves the result if it
    /// moved, and returns it. Saving is best effort: a cache that cannot be written (a
    /// read-only home, a full disk) never fails the read, it only stays stale.
    ///
    /// On a compacted ledger the archived segments are read first, so a cache rebuilds as
    /// usual. When they are gone too, a cache that does not continue the live events cannot be
    /// rebuilt from them; it is seeded from `archive/seeds/` instead, using the newest trusted
    /// checkpoint whose digest matches the seed. Without one it throws
    /// `ProjectionError.archived` rather than guessing.
    public func current<P: LedgerProjection & Codable>(_ type: P.Type, name: String) throws
        -> Projected<P>
    {
        let saved = load(type, name: name)
        var projected = saved ?? Projected<P>()
        do {
            try reader.catchUp(&projected)
        } catch ProjectionError.discontinuity {
            guard var seeded = try seed(type, name: name) else {
                throw ProjectionError.archived(name)
            }
            try reader.catchUp(&seeded)
            projected = seeded
        }
        if saved?.seq != projected.seq || saved?.hash != projected.hash {
            try? save(projected, name: name)
        }
        return projected
    }

    /// The newest seed a trusted checkpoint vouches for, or nil.
    func seed<P: LedgerProjection & Codable>(_ type: P.Type, name: String) throws
        -> Projected<P>?
    {
        guard Self.isValidName(name) else { return nil }
        let checkpoints = Checkpoints(home: directory.deletingLastPathComponent())
        let ring = try checkpoints.trustedRing()
        var found: [SystemCheckpoint] = []
        try reader.forEach(LedgerFilter(types: [.systemCheckpoint])) { event in
            if let value = try? event.payload(as: SystemCheckpoint.self),
                value.projections[name] != nil
            {
                found.append(value)
            }
        }
        for checkpoint in found.reversed() {
            guard Checkpoints.checkSignature(checkpoint, ring: ring) == nil,
                let digest = checkpoint.projections[name],
                let data = plaintext(
                    checkpoints.seedDirectory(checkpoint.through)
                        .appendingPathComponent(name + ".json"), name: name),
                case .object(let fields)? = try? JSONParser.parse(Array(data)),
                let value = fields["value"], (try? Checkpoints.digest(value)) == digest,
                let file = try? JSONDecoder().decode(CacheFile<P>.self, from: data),
                file.v == 1, file.name == name, file.seq == checkpoint.through,
                file.hash == checkpoint.head
            else { continue }
            return Projected(value: file.value, seq: file.seq, hash: file.hash)
        }
        return nil
    }

    /// Cache files in `cache/` exactly at `head`: name, value digest, and file bytes.
    func files(at head: Event) throws -> [(name: String, digest: String, bytes: [UInt8])] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [] }
        var out: [(name: String, digest: String, bytes: [UInt8])] = []
        for file in names.sorted() where file.hasSuffix(".json") {
            let name = String(file.dropLast(5))
            guard Self.isValidName(name),
                let raw = FileManager.default.contents(atPath: url(name).path),
                let data = plaintext(url(name), name: name),
                case .object(let fields)? = try? JSONParser.parse(Array(data)),
                fields["v"] == 1, fields["name"] == .string(name),
                fields["seq"] == .int(head.seq), fields["hash"] == .string(head.hash),
                let value = fields["value"]
            else { continue }
            out.append((name, try Checkpoints.digest(value), Array(raw)))
        }
        return out
    }

    /// The cache name of the ledger-owned `LedgerIndex`.
    public static let indexName = "ledger-index"

    /// The current `LedgerIndex` (run and steward spans, per-steward counters), from
    /// `cache/ledger-index.json`.
    public func index() throws -> Projected<LedgerIndex> {
        try current(LedgerIndex.self, name: Self.indexName)
    }

    /// Removes the cache file for `name`, if any.
    public func remove(name: String) {
        guard Self.isValidName(name) else { return }
        try? FileManager.default.removeItem(at: url(name))
    }

    func url(_ name: String) -> URL { directory.appendingPathComponent(name + ".json") }

    /// Lowercase letters, digits, `-`, and `.`; no path separators.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".")
            && name.utf8.allSatisfy {
                (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46
            }
    }
}

/// Projection cache errors.
public enum ProjectionCacheError: Error, Hashable, Sendable {
    case invalidName(String)
}

private struct CacheFile<P: Codable>: Codable {
    var v: Int
    var name: String
    var seq: Int64
    var hash: String
    var value: P

    enum CodingKeys: String, CodingKey { case v, name, seq, hash, value }
}
