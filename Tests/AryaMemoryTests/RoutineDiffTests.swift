import AryaCore
import Testing

@testable import AryaMemory

@Suite struct RoutineDiffTests {
    @Test func identicalTextsHaveNoChanges() {
        let diff = RoutineDiff(old: labelV1, new: labelV1)
        #expect(diff.isEmpty)
        #expect(diff.hunks().isEmpty)
        #expect(diff.unified() == "")
        #expect(RoutineDiff(old: "", new: "").lines.isEmpty)
    }

    @Test func unifiedOutputMatchesGolden() throws {
        let old = (1...12).map { "line \($0)" }.joined(separator: "\n") + "\n"
        var newLines = (1...12).map { "line \($0)" }
        newLines[1] = "line two"
        newLines.insert("inserted", at: 10)
        newLines.removeLast()
        let diff = RoutineDiff(old: old, new: newLines.joined(separator: "\n") + "\n")
        #expect(diff.added == 2)
        #expect(diff.removed == 2)
        #expect(diff.hunks(context: 2).count == 2)
        #expect(diff.unified(context: 2) == (try fixture("routine.diff.txt")))
    }

    @Test func emptySidesUseUnifiedHeaders() {
        let added = RoutineDiff(old: "", new: "a\nb\n").hunks()
        #expect(added.map(\.header) == ["@@ -0,0 +1,2 @@"])
        let removed = RoutineDiff(old: "a\n", new: "").hunks()
        #expect(removed.map(\.header) == ["@@ -1,1 +0,0 @@"])
    }

    @Test func lineNumbersPointIntoEachSide() {
        let diff = RoutineDiff(old: "a\nb\nc", new: "a\nc\nd")
        let rendered = diff.lines.map { line -> String in
            let o = line.oldNumber.map(String.init) ?? "-"
            let n = line.newNumber.map(String.init) ?? "-"
            return "\(line.kind.rawValue) \(o) \(n) \(line.text)"
        }
        #expect(rendered == ["same 1 1 a", "removed 2 - b", "same 3 2 c", "added - 3 d"])
    }

    @Test func trailingNewlineChangesAreVisibleOnlyAsContent() {
        #expect(RoutineDiff(old: "a\n", new: "a").isEmpty)
        #expect(RoutineDiff(old: "a\n", new: "a\n\n").added == 1)
    }

    /// Over seeded random inputs, the diff rebuilds both sides and is a shortest edit script.
    @Test func reconstructsAndIsMinimal() {
        var rng = SeededGenerator(42)
        for _ in 0..<300 {
            let a = (0..<Int.random(in: 0..<12, using: &rng)).map { _ in
                ["x", "y", "z", "w"][Int.random(in: 0..<4, using: &rng)]
            }
            let b = (0..<Int.random(in: 0..<12, using: &rng)).map { _ in
                ["x", "y", "z", "w"][Int.random(in: 0..<4, using: &rng)]
            }
            let lines = RoutineDiff.diff(a, b)
            #expect(lines.filter { $0.kind != .added }.map(\.text) == a)
            #expect(lines.filter { $0.kind != .removed }.map(\.text) == b)
            let edits = lines.filter { $0.kind != .same }.count
            #expect(edits == a.count + b.count - 2 * lcs(a, b), "\(a) -> \(b)")
        }
    }

    private func lcs(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 1...a.count {
            for j in 1...b.count {
                table[i][j] =
                    a[i - 1] == b[j - 1]
                    ? table[i - 1][j - 1] + 1 : max(table[i - 1][j], table[i][j - 1])
            }
        }
        return table[a.count][b.count]
    }
}
