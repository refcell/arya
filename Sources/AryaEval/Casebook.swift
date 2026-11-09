import AryaCore
import CryptoKit
import Foundation

/// One past unit of work, as stored in a casebook line (see ARCHITECTURE.md, "Charters and
/// cases"). Local to `AryaEval` until `AryaCore.Case` lands.
public struct EvalCase: Hashable, Sendable, Codable {
    public var v: Int
    public var id: CaseID
    public var input: JSONValue
    public var context: JSONValue
    public var expected: JSONValue
    public var source: String?

    public init(
        id: CaseID, input: JSONValue, context: JSONValue = .object([:]), expected: JSONValue,
        source: String? = nil
    ) {
        self.v = 1
        self.id = id
        self.input = input
        self.context = context
        self.expected = expected
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case v, id, input, context, expected, source
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        id = try c.decode(CaseID.self, forKey: .id)
        input = try c.decode(JSONValue.self, forKey: .input)
        context = try c.decodeIfPresent(JSONValue.self, forKey: .context) ?? .object([:])
        expected = try c.decode(JSONValue.self, forKey: .expected)
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }
}

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
    public var cases: [EvalCase]
    public var version: String

    /// Parses JSON Lines: one case per line; blank lines are ignored.
    public static func parse(name: String, data: Data) throws -> Casebook {
        let decoder = JSONDecoder()
        var cases: [EvalCase] = []
        var seen = Set<CaseID>()
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        for (offset, raw) in lines.enumerated() {
            let line = offset + 1
            let bytes = Data(raw)
            if bytes.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { continue }
            let item: EvalCase
            do {
                item = try decoder.decode(EvalCase.self, from: bytes)
            } catch {
                throw CasebookError.invalidLine(line: line, reason: "not a case object")
            }
            guard item.v == 1 else {
                throw CasebookError.unsupportedVersion(line: line, version: item.v)
            }
            guard seen.insert(item.id).inserted else {
                throw CasebookError.duplicateID(item.id.rawValue)
            }
            cases.append(item)
        }
        guard !cases.isEmpty else { throw CasebookError.empty }
        return try Casebook(name: name, cases: cases)
    }

    public init(name: String, cases: [EvalCase]) throws {
        self.name = name
        self.cases = cases.sorted { $0.id < $1.id }
        self.version = Self.hash(try Self.normalized(self.cases))
    }

    /// Canonical JSON Lines (`AryaCore.CanonicalJSON`), one case per line, each ending in
    /// `\n`.
    public func normalizedData() throws -> Data {
        try Self.normalized(cases)
    }

    static func normalized(_ cases: [EvalCase]) throws -> Data {
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
