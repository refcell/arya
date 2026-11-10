import CryptoKit
import Foundation

/// Content-addressed blobs under `blobs/sha256/ab/<hex>`, where `ab` is the first two hex digits
/// of the SHA-256 of the content. Writes are atomic (temp file in the same directory, `fsync`,
/// `rename`), so a reader never sees a partial blob, and a put of existing content is a no-op.
/// In an encrypted home (`HomeEncryption`) new blobs are sealed files; the key stays the
/// SHA-256 of the plaintext, and `get` opens and checks it.
public struct BlobStore: Sendable {
    /// The `blobs` directory.
    public let root: URL

    /// A store rooted at `home/blobs`.
    /// The home directory.
    public let home: URL

    public init(home: URL) {
        self.home = home
        root = home.appendingPathComponent("blobs", isDirectory: true)
    }

    /// The authenticated context of a sealed blob.
    static func context(_ hex: String) -> String { "blob|" + hex }

    /// Stores `data` and returns its lowercase hex SHA-256.
    @discardableResult
    public func put(_ data: Data) throws -> String {
        let hex = LedgerLine.hexSHA256(data)
        let url = path(hex)
        if FileManager.default.fileExists(atPath: url.path) { return hex }
        let dir = url.deletingLastPathComponent()
        try FileIO.makeDirectory(dir)
        try HomeEncryption.write(Array(data), to: url, home: home, context: Self.context(hex))
        return hex
    }

    /// The blob with `hex`. Throws `BlobError.missing` or `BlobError.corrupt`.
    public func get(_ hex: String) throws -> Data {
        guard Self.isValidKey(hex) else { throw BlobError.invalidKey(hex) }
        let url = path(hex)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw BlobError.missing(hex)
        }
        let plain: [UInt8]
        do {
            plain = try HomeEncryption.openFile(Array(data), home: home, context: Self.context(hex))
        } catch HomeEncryptionError.badBox {
            throw BlobError.corrupt(hex)
        }
        guard LedgerLine.hexSHA256(plain) == hex else { throw BlobError.corrupt(hex) }
        return Data(plain)
    }

    /// Every stored blob key, sorted.
    public func keys() throws -> [String] {
        let sha = root.appendingPathComponent("sha256", isDirectory: true)
        let fm = FileManager.default
        guard let prefixes = try? fm.contentsOfDirectory(atPath: sha.path) else { return [] }
        var out: [String] = []
        for prefix in prefixes where prefix.utf8.count == 2 {
            let dir = sha.appendingPathComponent(prefix, isDirectory: true)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            where Self.isValidKey(name) && name.hasPrefix(prefix) {
                out.append(name)
            }
        }
        return out.sorted()
    }

    /// Whether a blob with `hex` is stored.
    public func exists(_ hex: String) -> Bool {
        Self.isValidKey(hex) && FileManager.default.fileExists(atPath: path(hex).path)
    }

    /// Where the blob with `hex` lives (whether or not it exists).
    public func path(_ hex: String) -> URL {
        root.appendingPathComponent("sha256", isDirectory: true)
            .appendingPathComponent(String(hex.prefix(2)), isDirectory: true)
            .appendingPathComponent(hex)
    }

    /// 64 lowercase hex digits.
    public static func isValidKey(_ hex: String) -> Bool {
        hex.utf8.count == 64
            && hex.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// Blob store errors.
public enum BlobError: Error, Hashable, Sendable {
    case invalidKey(String)
    case missing(String)
    /// The stored bytes no longer hash to their key.
    case corrupt(String)
}
