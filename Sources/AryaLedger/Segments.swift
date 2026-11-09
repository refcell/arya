import Foundation

/// One ledger segment file, `ledger/000001.jsonl`.
public struct Segment: Hashable, Sendable, Comparable {
    public var number: Int
    public var url: URL

    public var name: String { url.lastPathComponent }

    public static func name(_ number: Int) -> String {
        let digits = String(number)
        return String(repeating: "0", count: max(0, 6 - digits.count)) + digits + ".jsonl"
    }

    public static func < (lhs: Segment, rhs: Segment) -> Bool { lhs.number < rhs.number }

    /// Segments in `dir`, oldest first. Files that do not look like segments are ignored.
    static func list(in dir: URL) throws -> [Segment] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        } catch {
            throw LedgerIOError(op: "list", path: dir.lastPathComponent, code: ENOENT)
        }
        return names.compactMap { name -> Segment? in
            guard name.hasSuffix(".jsonl"), name.utf8.count >= 12 else { return nil }
            let stem = name.dropLast(6)
            guard stem.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(stem),
                number > 0
            else { return nil }
            return Segment(number: number, url: dir.appendingPathComponent(name))
        }.sorted()
    }
}

/// The last line of a segment, found by scanning backwards from the end.
struct SegmentTail {
    /// Byte offset where the last line starts.
    var offset: Int64
    /// The line's bytes without the trailing newline.
    var line: [UInt8]
    /// Whether the file ends with `\n`.
    var terminated: Bool

    /// Reads the tail of an open segment; nil when the segment is empty.
    static func read(_ fd: Int32, name: String) throws -> SegmentTail? {
        let size = try FileIO.size(fd, name: name)
        if size == 0 { return nil }
        let lastByte = try FileIO.read(fd, at: size - 1, count: 1, name: name)
        let terminated = lastByte == [0x0A]
        let end = terminated ? size - 1 : size
        var start = end
        let chunk: Int64 = 64 * 1024
        var found = false
        while start > 0 && !found {
            let from = max(0, start - chunk)
            let bytes = try FileIO.read(fd, at: from, count: Int(start - from), name: name)
            if let newline = bytes.lastIndex(of: 0x0A) {
                start = from + Int64(newline) + 1
                found = true
            } else {
                start = from
            }
        }
        let line = try FileIO.read(fd, at: start, count: Int(end - start), name: name)
        return SegmentTail(offset: start, line: line, terminated: terminated)
    }
}
