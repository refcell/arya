import AryaCore
import Foundation

/// A cheap byte-level pre-check that lets a filtered read skip lines before hashing and
/// parsing them. It only ever rejects lines that cannot match the filter: every needle is a
/// fragment the canonical writer must have produced for a matching event, so a line without
/// it cannot match. Lines it passes still go through `LedgerLine.open` and
/// `LedgerFilter.matches`. Skipped lines are not hash-checked; `LedgerVerifier` is the
/// integrity check.
struct LineSieve: Sendable {
    /// Each group must have at least one needle present in the line.
    private var groups: [[[UInt8]]] = []
    /// Lowest and highest `at` (inclusive and exclusive), as canonical text bytes.
    private var since: Timestamp?
    private var until: Timestamp?

    /// Whether the sieve passes every line, so callers can skip calling it.
    var passesAll: Bool { groups.isEmpty && since == nil && until == nil }

    init(_ filter: LedgerFilter) {
        since = filter.since
        until = filter.until
        if let steward = filter.steward {
            groups.append([Self.member("steward", steward.rawValue)])
        }
        if let run = filter.run { groups.append([Self.member("run", run.rawValue)]) }
        if !filter.types.isEmpty {
            groups.append(filter.types.sorted().map { Self.member("type", $0.rawValue) })
        }
        if !filter.namespaces.isEmpty {
            // `"type":"run` is a prefix of every type in the `run` namespace.
            groups.append(
                filter.namespaces.sorted().map { Array(Self.member("type", $0).dropLast(1)) })
        }
        if let kind = filter.actorKind {
            groups.append([Self.member("kind", kind.rawValue) + [UInt8(ascii: "}")]])
        }
        if let id = filter.actorID {
            groups.append([Array(#"{"actor":{"#.utf8) + Self.member("id", id)])
        }
    }

    /// Whether `line` may match the filter.
    func admits(_ line: UnsafeBufferPointer<UInt8>) -> Bool {
        for group in groups {
            var found = false
            for needle in group where Self.contains(line, needle) {
                found = true
                break
            }
            if !found { return false }
        }
        if since == nil && until == nil { return true }
        guard let at = Self.at(of: line) else { return true }
        if let since, at < since { return false }
        if let until, at >= until { return false }
        return true
    }

    // MARK: - Internals

    /// `"key":"value"` exactly as the canonical writer encodes it.
    private static func member(_ key: String, _ value: String) -> [UInt8] {
        var out = [UInt8]()
        // Strings always encode; a failure would only make the sieve stricter, so fall back
        // to the raw bytes, which match for every id and type arya writes.
        if (try? CanonicalJSON.write(.string(key), into: &out)) == nil {
            out = Array("\"\(key)\"".utf8)
        }
        out.append(UInt8(ascii: ":"))
        var encoded = [UInt8]()
        if (try? CanonicalJSON.write(.string(value), into: &encoded)) == nil {
            encoded = Array("\"\(value)\"".utf8)
        }
        return out + encoded
    }

    private static func contains(_ line: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        guard let base = line.baseAddress, !needle.isEmpty else { return true }
        return needle.withUnsafeBytes { raw in
            memmem(base, line.count, raw.baseAddress, raw.count) != nil
        }
    }

    private static let atKey = Array(#""at":""#.utf8)

    /// The envelope's `at`. Keys are sorted, so `"at":"` first appears right after the actor
    /// object (`{"id":…,"kind":…}`), whose strings escape every quote. Nil when unreadable,
    /// which makes the sieve pass the line to the full check.
    static func at(of line: UnsafeBufferPointer<UInt8>) -> Timestamp? {
        guard let base = line.baseAddress else { return nil }
        let hit = atKey.withUnsafeBytes { raw in
            memmem(base, line.count, raw.baseAddress, raw.count)
        }
        guard let hit else { return nil }
        let start = base.distance(to: hit.assumingMemoryBound(to: UInt8.self)) + atKey.count
        guard let quote = memchr(base + start, 0x22, line.count - start) else { return nil }
        let end = base.distance(to: quote.assumingMemoryBound(to: UInt8.self))
        return Timestamp(
            String(
                decoding: UnsafeBufferPointer(rebasing: line[start..<end]),
                as: UTF8.self))
    }
}
