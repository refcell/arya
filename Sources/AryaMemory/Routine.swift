import AryaCore
import CryptoKit
import Foundation

/// What a routine is written in. `sh` routines run as shell scripts through the `routine`
/// action kind; `prompt` routines are text a steward reads, never executed.
public enum RoutineLanguage: String, Codable, Sendable, Equatable, CaseIterable {
    case sh
    case prompt
}

/// Reasons a routine is rejected.
public enum RoutineError: Error, Equatable, Sendable {
    case invalidName(String)
    case unknownLanguage(String)
    case emptyContent
    case contentTooLarge(bytes: Int, limit: Int)
    case invalidVersion(String)
    case duplicateName(String)
}

/// Routine names and versions.
public enum RoutineNaming {
    /// Longest accepted name, in bytes.
    public static let maxNameBytes = 64

    /// Whether `name` is 1-64 bytes of `[a-z0-9_.-]` starting with a letter or digit.
    public static func isValid(name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard let first = bytes.first, bytes.count <= maxNameBytes, isLowerAlnum(first) else {
            return false
        }
        return bytes.allSatisfy {
            isLowerAlnum($0) || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: ".")
                || $0 == UInt8(ascii: "-")
        }
    }

    /// Whether `version` is 64 lowercase hex digits (a SHA-256).
    public static func isValid(version: String) -> Bool {
        version.utf8.count == 64
            && version.utf8.allSatisfy {
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                    || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
            }
    }

    /// The version of `content`: the lowercase hex SHA-256 of its bytes, which is also the
    /// key of the blob that stores it.
    public static func version(of content: Data) -> String {
        SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
    }

    private static func isLowerAlnum(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }
}

/// A routine's source and its content-addressed version.
public struct RoutineSource: Sendable, Equatable {
    /// Largest accepted routine, in UTF-8 bytes.
    public static let maxContentBytes = 256 * 1024

    public var name: String
    public var language: RoutineLanguage
    public var content: String
    /// Lowercase hex SHA-256 of `content` as UTF-8.
    public var version: String { RoutineNaming.version(of: data) }
    /// `content` as stored in the blob.
    public var data: Data { Data(content.utf8) }

    /// Validates a routine. `language` is the wire string (`sh` or `prompt`).
    public init(name: String, language: String, content: String) throws(RoutineError) {
        guard let parsed = RoutineLanguage(rawValue: language) else {
            throw .unknownLanguage(language)
        }
        try self.init(name: name, language: parsed, content: content)
    }

    public init(name: String, language: RoutineLanguage, content: String)
        throws(RoutineError)
    {
        guard RoutineNaming.isValid(name: name) else { throw .invalidName(name) }
        guard !content.trimmingWhitespace().isEmpty else { throw .emptyContent }
        let bytes = content.utf8.count
        guard bytes <= Self.maxContentBytes else {
            throw .contentTooLarge(bytes: bytes, limit: Self.maxContentBytes)
        }
        self.name = name
        self.language = language
        self.content = content
    }

    /// A one-line description: the first line of `reason`, else the first comment line of the
    /// content (after any `#!` line), else the name. At most 120 bytes, cut on a character.
    public func summary(reason: String?) -> String {
        let fromReason = reason.flatMap { Self.firstLine($0) }
        let fromComment = content.split(separator: "\n", omittingEmptySubsequences: true)
            .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("#") && !$0.hasPrefix("#!") }
            .compactMap { Self.firstLine(String($0.drop { $0 == "#" })) }.first
        return Self.clip(fromReason ?? fromComment ?? name, bytes: 120)
    }

    private static func firstLine(_ text: String) -> String? {
        let line = text.split(separator: "\n").first.map(String.init)?.trimmingWhitespace()
        return line?.isEmpty == false ? line : nil
    }

    private static func clip(_ text: String, bytes limit: Int) -> String {
        var out = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            guard used + size <= limit else { break }
            out.append(character)
            used += size
        }
        return out
    }
}

/// Where routine content lives: the home's `AryaLedger.BlobStore`, or an in-memory store in
/// tests. Keys are the lowercase hex SHA-256 of the content.
public protocol RoutineBlobStore: Sendable {
    /// Stores `data` and returns its key (the lowercase hex SHA-256).
    func put(_ data: Data) throws -> String
    /// The blob with this key, or nil when none is stored.
    func getIfPresent(_ key: String) throws -> Data?
}

/// An in-memory `RoutineBlobStore` for tests and rehearsal.
public final class InMemoryRoutineBlobStore: RoutineBlobStore, @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [String: Data] = [:]

    public init() {}

    public func put(_ data: Data) throws -> String {
        let key = RoutineNaming.version(of: data)
        lock.withLock { blobs[key] = data }
        return key
    }

    public func getIfPresent(_ key: String) throws -> Data? {
        lock.withLock { blobs[key] }
    }

    /// Replaces a blob's bytes without rehashing, to test corruption handling.
    public func overwrite(_ key: String, with data: Data) {
        lock.withLock { blobs[key] = data }
    }
}
