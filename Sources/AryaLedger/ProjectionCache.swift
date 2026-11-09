import AryaCore
import Foundation

/// Saved projections in `home/cache/<name>.json`, so opening a large ledger does not refold it
/// from the start. Safe to delete: a missing, corrupt, or stale cache only costs a rebuild.
///
/// File format: `{"v":1,"name":…,"seq":…,"hash":…,"value":{…}}`, where `seq` and
/// `hash` name the last folded event. Writes are atomic (temp file and rename).
public struct ProjectionCache: Sendable {
    /// `home/cache`.
    public let directory: URL
    public let reader: LedgerReader

    public init(home: URL) {
        directory = home.appendingPathComponent("cache", isDirectory: true)
        reader = LedgerReader(home: home)
    }

    /// The saved projection, or nil if there is none or it cannot be read.
    public func load<P: LedgerProjection & Codable>(_ type: P.Type, name: String) -> Projected<P>? {
        guard Self.isValidName(name),
            let data = FileManager.default.contents(atPath: url(name).path),
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
        try FileIO.atomicWrite(try CanonicalJSON.encode(file), to: url(name))
    }

    /// Loads the cache (or starts empty), catches up with the ledger, saves the result if it
    /// moved, and returns it. Saving is best effort: a cache that cannot be written (a
    /// read-only home, a full disk) never fails the read, it only stays stale.
    public func current<P: LedgerProjection & Codable>(_ type: P.Type, name: String) throws
        -> Projected<P>
    {
        let saved = load(type, name: name)
        var projected = saved ?? Projected<P>()
        try reader.catchUp(&projected)
        if saved?.seq != projected.seq || saved?.hash != projected.hash {
            try? save(projected, name: name)
        }
        return projected
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
