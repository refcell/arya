/// A small line diff producing unified diff text for `DiffBlock`. Routines are short scripts,
/// so a quadratic longest-common-subsequence table is fine.
enum LineDiff {
    enum Edit: Hashable, Sendable {
        case same(String)
        case removed(String)
        case added(String)
    }

    /// The edits that turn `old` into `new`, in order.
    static func edits(_ old: [String], _ new: [String]) -> [Edit] {
        let rows = old.count
        let cols = new.count
        var lcs = Array(repeating: Array(repeating: 0, count: cols + 1), count: rows + 1)
        for i in stride(from: rows - 1, through: 0, by: -1) {
            for j in stride(from: cols - 1, through: 0, by: -1) {
                lcs[i][j] =
                    old[i] == new[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var out: [Edit] = []
        var i = 0
        var j = 0
        while i < rows || j < cols {
            if i < rows, j < cols, old[i] == new[j] {
                out.append(.same(old[i]))
                i += 1
                j += 1
            } else if j < cols, i == rows || lcs[i][j + 1] >= lcs[i + 1][j] {
                out.append(.added(new[j]))
                j += 1
            } else {
                out.append(.removed(old[i]))
                i += 1
            }
        }
        return out
    }

    /// Unified diff text with one hunk covering both files. Empty when they are equal.
    static func unified(old: String, new: String, oldLabel: String, newLabel: String) -> String {
        let a = lines(old)
        let b = lines(new)
        let changes = edits(a, b)
        guard changes.contains(where: { if case .same = $0 { false } else { true } }) else {
            return ""
        }
        var out = ["--- \(oldLabel)", "+++ \(newLabel)", "@@ -1,\(a.count) +1,\(b.count) @@"]
        for change in changes {
            switch change {
            case .same(let line): out.append(" " + line)
            case .removed(let line): out.append("-" + line)
            case .added(let line): out.append("+" + line)
            }
        }
        return out.joined(separator: "\n")
    }

    private static func lines(_ text: String) -> [String] {
        var parts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "" { parts.removeLast() }
        return parts
    }
}
