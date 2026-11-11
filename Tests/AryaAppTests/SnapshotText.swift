import AppKit
import Foundation
import Testing
import Vision

@testable import AryaApp

/// The raw-id gate (STYLE.md "Raw ids"): every line of text in a rendered state is read
/// back, and a machine id outside the run's TOOLS and LOG panes fails the snapshot run. Those
/// panes show tool input and output verbatim, so lines that read as JSON or log fields (`{`,
/// `"`, `=`) are left out, and `allowed` lists the few exact strings that may keep an id.
@MainActor
enum SnapshotText {
    /// Ids a person should never read: `person:sam`, `st_triage`, `cmt:CMT-1060`, and any
    /// snake-case key (`act_medium`, `send_email`, `routed_within_1h`); metric keys too. An
    /// opaque id after the underscore (`ev_01M7…`, `key_3f…`) is a ledger or key id, not a key.
    static let pattern = try! NSRegularExpression(
        pattern: #"person:|st_[a-z]|\b[a-z]+:[A-Z]{2,}-\d+|\b[a-z]+_[a-z][a-z0-9]*"#)

    /// Exact strings that may show a snake-case word: the run OUTPUT pane's verbatim wire
    /// method names.
    static let allowed: [String] = ["tool_call", "tool_result"]

    /// States excused for a while (`etc/app/rawtext-pending.txt`, owner, date, and reason on
    /// each line): reported, not failed. Every other state fails on its first raw id.
    static let pending: Set<String> = Set(pendingLines().map(\.state))

    /// One line of the pending file: `<state> <lane> <YYYY-MM-DD> <reason>`.
    struct PendingLine: Equatable {
        var state: String
        var lane: String
        var date: String
        var reason: String

        /// Nil unless the line has all four parts and a real date.
        static func parse(_ line: String) -> PendingLine? {
            let parts = line.split(separator: " ", maxSplits: 3).map(String.init)
            guard parts.count == 4, !parts[3].trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            let day = DateFormatter()
            day.locale = Locale(identifier: "en_US_POSIX")
            day.dateFormat = "yyyy-MM-dd"
            guard day.date(from: parts[2]) != nil else { return nil }
            return PendingLine(state: parts[0], lane: parts[1], date: parts[2], reason: parts[3])
        }
    }

    /// The pending file's lines that are not comments or blank, as written.
    static func pendingText() -> [String] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../etc/app/rawtext-pending.txt").standardizedFileURL
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Well-formed pending lines only: a line without owner, date, and reason excuses nothing.
    static func pendingLines() -> [PendingLine] { pendingText().compactMap(PendingLine.parse) }

    /// Every line of text in the rendered PNG, read with the system's text recognizer
    /// (offscreen hosting views build no accessibility tree): what a person would read.
    static func read(_ png: Data) -> [String] {
        guard let image = NSBitmapImageRep(data: png)?.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    /// The strings that show a raw id, verbatim pane lines and allowed strings left out.
    static func offenders(_ texts: [String]) -> [String] {
        var seen: Set<String> = []
        return texts.filter { text in
            guard !seen.contains(text) else { return false }
            seen.insert(text)
            if text.contains("{") || text.contains("\"") || text.contains("=") { return false }
            if allowed.contains(where: text.contains) { return false }
            // OCR may read "_" as "." inside a snake-case word: detect it either way.
            let line = text.split(separator: " ").map { word -> String in
                word.contains("_") ? word.replacingOccurrences(of: ".", with: "_") : String(word)
            }.joined(separator: " ")
            let range = NSRange(line.startIndex..., in: line)
            return pattern.firstMatch(in: line, range: range) != nil
        }
    }

    /// Writes `rawtext-<file>.txt` with the offenders next to the PNG and records an issue.
    static func check(_ file: String, png: Data, dir: String?) {
        let last = read(png)
        let bad = offenders(last)
        // ARYA_SNAPSHOT_TEXTS=1 keeps every collected string, to tune the gate.
        if let dir, ProcessInfo.processInfo.environment["ARYA_SNAPSHOT_TEXTS"] != nil {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("texts-\(file).txt")
            try? last.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        guard !bad.isEmpty else { return }
        if let dir {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("rawtext-\(file).txt")
            try? bad.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        let state = String(file.dropLast(4))
        guard !pending.contains(state) else { return }
        Issue.record(
            Comment(rawValue: "\(file) shows raw ids: " + bad.prefix(6).joined(separator: " | ")))
    }
}

@MainActor @Test func rawIdPendingLinesNameAnOwnerADateAndAReason() {
    for line in SnapshotText.pendingText() {
        #expect(
            SnapshotText.PendingLine.parse(line) != nil,
            Comment(
                rawValue: "rawtext-pending.txt needs <state> <lane> <YYYY-MM-DD> <reason>: " + line)
        )
    }
    #expect(SnapshotText.PendingLine.parse("overview app-outcome") == nil)
    #expect(SnapshotText.PendingLine.parse("overview app-outcome soon fixing it") == nil)
    #expect(
        SnapshotText.PendingLine.parse("overview app-outcome 2026-11-11 seed note shows person:lee")
            != nil)
}

@Test func peopleCountOnePersonOnce() {
    #expect(StewardContext.personKey("person:sam") == StewardContext.personKey("sam"))
    #expect(StewardContext.personKey("Sam") == StewardContext.personKey("person:sam"))
    #expect(StewardContext.personKey("person:lee") != StewardContext.personKey("person:sam"))
}

@MainActor @Test func rawIdGateFailsEverySnakeCaseKey() {
    let lines = [
        "0.96 / 0.95 routed_within_1h", "Acts alone on medium risk", "first_reply.within_1d",
    ]
    #expect(
        SnapshotText.offenders(lines) == ["0.96 / 0.95 routed_within_1h", "first_reply.within_1d"])
}
