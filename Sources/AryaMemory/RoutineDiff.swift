/// A line-based diff between two routine versions, for the app's version view.
public struct RoutineDiff: Sendable, Equatable {
    /// One line of a diff.
    public struct Line: Sendable, Equatable {
        public enum Kind: String, Sendable, Equatable {
            case same
            case added
            case removed
        }

        public var kind: Kind
        public var text: String
        /// 1-based line number in the old text (nil for added lines).
        public var oldNumber: Int?
        /// 1-based line number in the new text (nil for removed lines).
        public var newNumber: Int?
    }

    /// A run of changes with surrounding context, as in a unified diff.
    public struct Hunk: Sendable, Equatable {
        public var oldStart: Int
        public var oldCount: Int
        public var newStart: Int
        public var newCount: Int
        public var lines: [Line]

        /// `@@ -a,b +c,d @@`, with the unified-diff convention that an empty side starts at
        /// the line before it.
        public var header: String {
            "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
        }
    }

    /// Every line of both texts in order.
    public var lines: [Line]

    /// Diffs `old` against `new` by lines. A trailing newline does not create an empty last
    /// line; `\r\n` is treated as two characters, so line endings show up as changes.
    public init(old: String, new: String) {
        lines = Self.diff(Self.split(old), Self.split(new))
    }

    public var added: Int { lines.filter { $0.kind == .added }.count }
    public var removed: Int { lines.filter { $0.kind == .removed }.count }
    public var isEmpty: Bool { added == 0 && removed == 0 }

    /// Changes grouped into hunks with `context` unchanged lines around each.
    public func hunks(context: Int = 3) -> [Hunk] {
        let changed = lines.indices.filter { lines[$0].kind != .same }
        guard !changed.isEmpty else { return [] }
        var ranges: [ClosedRange<Int>] = []
        for index in changed {
            let low = max(0, index - context)
            let high = min(lines.count - 1, index + context)
            if let last = ranges.last, low <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, high)
            } else {
                ranges.append(low...high)
            }
        }
        return ranges.map { hunk(Array(lines[$0]), before: Array(lines[..<$0.lowerBound])) }
    }

    /// The diff as unified-diff text (hunks only, no file headers).
    public func unified(context: Int = 3) -> String {
        hunks(context: context).flatMap { hunk -> [String] in
            [hunk.header]
                + hunk.lines.map { line in
                    switch line.kind {
                    case .same: return " " + line.text
                    case .added: return "+" + line.text
                    case .removed: return "-" + line.text
                    }
                }
        }.joined(separator: "\n")
    }

    private func hunk(_ slice: [Line], before: [Line]) -> Hunk {
        let oldCount = slice.filter { $0.kind != .added }.count
        let newCount = slice.filter { $0.kind != .removed }.count
        let oldBefore = before.filter { $0.kind != .added }.count
        let newBefore = before.filter { $0.kind != .removed }.count
        return Hunk(
            oldStart: oldCount == 0 ? oldBefore : oldBefore + 1, oldCount: oldCount,
            newStart: newCount == 0 ? newBefore : newBefore + 1, newCount: newCount,
            lines: slice)
    }

    static func split(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var parts = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if text.hasSuffix("\n") { parts.removeLast() }
        return parts
    }

    /// Myers' O(ND) shortest edit script, removals before additions within a change.
    static func diff(_ a: [String], _ b: [String]) -> [Line] {
        let trace = forwardTrace(a, b)
        var x = a.count
        var y = b.count
        var reversed: [Line] = []
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let v = trace[d]
            let offset = a.count + b.count
            let k = x - y
            let down = k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])
            let prevK = down ? k + 1 : k - 1
            let prevX = d == 0 ? 0 : v[offset + prevK]
            let prevY = prevX - prevK
            while x > prevX && y > prevY {
                reversed.append(Line(kind: .same, text: a[x - 1], oldNumber: x, newNumber: y))
                x -= 1
                y -= 1
            }
            guard d > 0 else { break }
            if down {
                reversed.append(Line(kind: .added, text: b[y - 1], oldNumber: nil, newNumber: y))
            } else {
                reversed.append(
                    Line(kind: .removed, text: a[x - 1], oldNumber: x, newNumber: nil))
            }
            x = prevX
            y = prevY
        }
        return reversed.reversed()
    }

    /// The `v` array after each edit distance `d`, until both texts are consumed.
    private static func forwardTrace(_ a: [String], _ b: [String]) -> [[Int]] {
        let n = a.count
        let m = b.count
        let offset = n + m
        var v = [Int](repeating: 0, count: 2 * offset + 2)
        var trace: [[Int]] = []
        for d in 0...offset {
            for k in stride(from: -d, through: d, by: 2) {
                let down = k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])
                var x = down ? v[offset + k + 1] : v[offset + k - 1] + 1
                var y = x - k
                while x < n && y < m && a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[offset + k] = x
                if x >= n && y >= m {
                    trace.append(v)
                    return trace
                }
            }
            trace.append(v)
        }
        return trace
    }
}
