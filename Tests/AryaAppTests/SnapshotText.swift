import AppKit
import Foundation
import Testing
import Vision

/// The raw-id gate (STYLE.md "Raw ids"): every line of text in a rendered state is read
/// back, and a machine id outside the run's TOOLS and LOG panes fails the snapshot run. Those
/// panes show tool input and output verbatim, so lines that read as JSON or log fields (`{`,
/// `"`, `=`) are left out, and `allowed` lists the few exact strings that may keep an id.
@MainActor
enum SnapshotText {
    /// Ids a person should never read: `person:sam`, `st_triage`, `cmt:CMT-1060`, `act_medium`.
    static let pattern = try! NSRegularExpression(
        pattern: #"person:|st_[a-z]|\b[a-z]+:[A-Z]{2,}-\d+|_[a-z]+_"#)

    /// Metric names are the charter's own words and are shown as written; the gate drops them
    /// from a line before matching. Add a metric here when a seeded charter gains one.
    static let metricNames = [
        "at_risk_with_plan", "chased_within_2d", "commitments_met_on_time",
        "confirmed_within_1d", "digests_before_shift", "digests_on_time",
        "first_reply_within_1d", "lapsed_accounts_followed_up", "notes_within_1d",
        "renewals_reviewed_on_time", "routed_within_1h",
    ]

    /// Exact strings that may show an id.
    static let allowed: [String] = []

    /// States known to show raw ids, with their owning lane (`etc/app/rawtext-pending.txt`):
    /// reported, not failed, until the owner fixes them and removes the line. Every other
    /// state fails on its first raw id, so a clean state can never regress.
    static let pending: Set<String> = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../etc/app/rawtext-pending.txt").standardizedFileURL
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return Set(
            text.split(separator: "\n").compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
                return trimmed.split(separator: " ").first.map(String.init)
            })
    }()

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
            // OCR may split a metric name at a space, so any snake-case word that is part of
            // a metric name counts as the metric.
            let line = text.split(separator: " ").map { word -> String in
                let bare = word.trimmingCharacters(in: .punctuationCharacters)
                return bare.contains("_") && metricNames.contains(where: { $0.contains(bare) })
                    ? "metric" : String(word)
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
