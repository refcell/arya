import AryaCore
import CryptoKit
import Foundation

/// Why a casebook could not be read. Line numbers start at 1.
public enum CasebookError: Error, Equatable, Sendable {
    case invalidLine(line: Int, reason: String)
    case unsupportedVersion(line: Int, version: Int)
    case duplicateID(String)
    case empty
}

/// A versioned set of cases. Cases are sorted by id; the version is the lowercase hex SHA-256
/// of the normalized content, so reordering lines or reformatting JSON keeps the version.
public struct Casebook: Hashable, Sendable {
    public var name: String
    public var cases: [Case]
    public var version: String

    /// Parses JSON Lines: one case per line; blank lines are ignored.
    public static func parse(name: String, data: Data) throws -> Casebook {
        var cases: [Case] = []
        var seen = Set<CaseID>()
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        for (offset, raw) in lines.enumerated() {
            let line = offset + 1
            let bytes = Data(raw)
            if bytes.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { continue }
            let item = try parseLine(bytes, line: line)
            guard seen.insert(item.id).inserted else {
                throw CasebookError.duplicateID(item.id.rawValue)
            }
            cases.append(item)
        }
        guard !cases.isEmpty else { throw CasebookError.empty }
        return try Casebook(name: name, cases: cases)
    }

    /// Decodes and validates one line with `Case.load`.
    static func parseLine(_ bytes: Data, line: Int) throws -> Case {
        do {
            return try Case.load(from: bytes)
        } catch CaseError.invalid(let issues) {
            if issues.contains(where: { $0.path == "v" }),
                let probe = try? JSONDecoder().decode(VersionProbe.self, from: bytes)
            {
                throw CasebookError.unsupportedVersion(line: line, version: probe.v)
            }
            let reason = issues.map(\.description).joined(separator: "; ")
            throw CasebookError.invalidLine(line: line, reason: reason)
        } catch {
            throw CasebookError.invalidLine(line: line, reason: "not a case object")
        }
    }

    private struct VersionProbe: Decodable { var v: Int }

    public init(name: String, cases: [Case]) throws {
        self.name = name
        self.cases = cases.sorted { $0.id < $1.id }
        self.version = Self.hash(try Self.normalized(self.cases))
    }

    /// Canonical JSON Lines (`AryaCore.CanonicalJSON`), one case per line, each ending in
    /// `\n`.
    public func normalizedData() throws -> Data {
        try Self.normalized(cases)
    }

    static func normalized(_ cases: [Case]) throws -> Data {
        var out = Data()
        for item in cases {
            out.append(try CanonicalJSON.encode(item))
            out.append(UInt8(ascii: "\n"))
        }
        return out
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
