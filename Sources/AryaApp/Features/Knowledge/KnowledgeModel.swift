import Foundation

/// The Knowledge screen as the workspace writes it: live notes with a provenance sentence, and
/// routines with every version and its approval state. Times follow `AryaTime.label`.
struct FeatureKnowledge: Hashable, Sendable {
    struct Note: Identifiable, Hashable, Sendable {
        /// The note id; shown only in the inspector, never in a row.
        var id: String
        var text: String
        /// "From your correction to case case-0003." or "Learned in run Refund for a charge."
        var provenance: String
        var time: String
        var absoluteTime: String
        var run: String?
    }

    struct Version: Hashable, Sendable {
        var version: String
        var summary: String
        /// "Live", "Waiting for approval", "Replaced by a newer version".
        var approval: String
        var time: String
    }

    struct Routine: Identifiable, Hashable, Sendable {
        var name: String
        var summary: String
        /// Newest first.
        var versions: [Version]
        var isLive: Bool
        var pending: Int

        var id: String { name }

        /// One plain word for the row: "live", "waiting", or "not live".
        var status: String {
            if pending > 0 { return "waiting" }
            return isLive ? "live" : "not live"
        }
    }

    var notes: [Note]
    var routines: [Routine]
}

enum KnowledgeText {
    /// "sha256:1a2b3c…" as the short form shown in version rows: "1a2b3c4d".
    static func shortVersion(_ version: String) -> String {
        String((version.split(separator: ":").last.map(String.init) ?? version).prefix(8))
    }

    /// The muted line under a note: its provenance sentence and when.
    static func provenance(_ note: FeatureKnowledge.Note) -> String {
        var sentence = note.provenance
        if sentence.hasSuffix(".") { sentence.removeLast() }
        // The workspace writes "case case-0006"; the id already says it is a case.
        sentence = sentence.replacingOccurrences(of: "case case-", with: "case-")
        return sentence.isEmpty ? note.time : "\(sentence) · \(note.time)"
    }
}
