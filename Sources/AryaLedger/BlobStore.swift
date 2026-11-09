import CryptoKit
import Foundation

/// Content-addressed blobs under `blobs/sha256/ab/<hex>`, where `ab` is the first two hex digits
/// of the SHA-256 of the content. Writes are atomic (temp file in the same directory, `fsync`,
/// `rename`), so a reader never sees a partial blob, and a put of existing content is a no-op.
public struct BlobStore: Sendable {
    /// The `blobs` directory.
    public let root: URL

    /// A store rooted at `home/blobs`.
    public init(home: URL) {
        root = home.appendingPathComponent("blobs", isDirectory: true)
    }

    /// Stores `data` and returns its lowercase hex SHA-256.
    @discardableResult
    public func put(_ data: Data) throws -> String {
        let hex = LedgerLine.hexSHA256(data)
        let url = path(hex)
        if FileManager.default.fileExists(atPath: url.path) { return hex }
        let dir = url.deletingLastPathComponent()
        try FileIO.makeDirectory(dir)
        try FileIO.atomicWrite(data, to: url)
        return hex
    }

    /// The blob with `hex`. Throws `BlobError.missing` or `BlobError.corrupt`.
    public func get(_ hex: String) throws -> Data {
        guard Self.isValidKey(hex) else { throw BlobError.invalidKey(hex) }
        let url = path(hex)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw BlobError.missing(hex)
        }
        guard LedgerLine.hexSHA256(data) == hex else { throw BlobError.corrupt(hex) }
        return data
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
