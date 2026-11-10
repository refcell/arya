import AryaCore
import AryaEval
import AryaLedger
import AryaRuntime
import Foundation

// One call per screen: the Improve and Knowledge screens read everything they show here, with
// sentences already written, so the views stay thin.

/// Everything the Improve screen shows for one steward.
public struct ImproveView: Sendable, Hashable, Codable {
    /// One case of the newest live rehearsal: what the steward would have done next to what the
    /// case expects.
    public struct CaseReview: Sendable, Hashable, Codable {
        public var caseID: String
        public var input: String
        /// What the run did, in words, for example `chose billing; label inbox:MSG-1`.
        public var wouldHave: String
        /// The expected result in words.
        public var expected: String
        /// The differences in a line, or `matches expected`.
        public var diff: String
        /// The score in one sentence.
        public var score: String
        public var passed: Bool
        public var leak: Bool
        /// Corrections a person recorded for this case from this rehearsal.
        public var corrections: Int
    }

    /// One proposal with its gate state in words.
    public struct ProposalItem: Sendable, Hashable, Codable {
        public var proposal: ProposalSummary
        /// For example "Passed the gate: mean 0.95 against 0.90." or "Not checked yet.".
        public var gate: String
    }

    public var steward: String
    /// The newest rehearsal of a live charter version, if any.
    public var rehearsal: RehearsalSummary?
    /// For example "Passed 4 of 5 cases on inbox (charter v2), mean score 0.92."
    public var rehearsalText: String
    public var ready: Bool
    public var markedReady: Bool
    /// The readiness line, shown verbatim: `ready: 8/8 passed, no regressions`.
    public var readinessText: String
    /// Every readiness reason, first one first.
    public var readinessReasons: [String]
    /// Newest first.
    public var proposals: [ProposalItem]
    public var cases: [CaseReview]
}

/// Everything the Knowledge screen shows for one steward.
public struct KnowledgeView: Sendable, Hashable, Codable {
    /// A memory note and where it came from.
    public struct Note: Sendable, Hashable, Codable {
        public var note: MemorySummary
        /// For example "From your correction to case case-0003." or "Learned in run Refund
        /// for a duplicate charge."
        public var provenance: String
        public var time: TimeText
    }

    /// One version of a routine and its approval state.
    public struct RoutineVersion: Sendable, Hashable, Codable {
        public var version: String
        public var summary: String
        public var gate: RoutineDetail.GateStatus
        /// For example "Live", "Waiting for approval", "Replaced by a newer version".
        public var approval: String
        public var time: TimeText
    }

    /// A routine with every version, newest first.
    public struct Routine: Sendable, Hashable, Codable {
        public var routine: RoutineSummary
        public var versions: [RoutineVersion]
    }

    public var steward: String
    /// Live notes, newest first.
    public var notes: [Note]
    /// Live notes every steward recalls, newest first.
    public var shared: [Note]
    public var routines: [Routine]
}

extension Workspace {
    /// The Improve screen for one steward: newest live rehearsal with per-case review,
    /// readiness, and proposals with their gate state.
    public func improve(steward: String) async throws -> ImproveView {
        let record = try await existing(steward)
        let readiness = try await ReadinessReports(sink: sink).report(record.id)
        let rehearsals = try await self.rehearsals(steward: steward)
        let rehearsal =
            readiness.rehearsal.flatMap { id in rehearsals.first { $0.id == id.rawValue } }
            ?? rehearsals.first { $0.charterVersion > 0 }
        var cases: [ImproveView.CaseReview] = []
        if let rehearsal {
            let report = try await RehearsalReports(sink: sink, casebooks: casebookSource)
                .report(RehearsalID(unchecked: rehearsal.id))
            cases = report.cases.map(Self.review)
        }
        return ImproveView(
            steward: record.id.rawValue, rehearsal: rehearsal,
            rehearsalText: rehearsal.map(Self.sentence) ?? "Not rehearsed yet.",
            ready: readiness.ready, markedReady: readiness.markedReady,
            readinessText: readiness.summary, readinessReasons: readiness.reasons.map(\.message),
            proposals: try await proposals(steward: steward).map {
                .init(proposal: $0, gate: Self.gateText($0))
            },
            cases: cases)
    }

    /// The Knowledge screen for one steward: live memory notes with where each came from, and
    /// routines with every version and its approval state.
    public func knowledge(steward: String, timeZone: TimeZone = .current) async throws
        -> KnowledgeView
    {
        let id = try await existing(steward).id
        let events = try facadeState().events
        let times = Dictionary(
            events.map { (Int($0.seq), $0.at.date) }, uniquingKeysWith: { first, _ in first })
        let now = now()
        func time(_ seq: Int) -> TimeText {
            TimeText(
                times[seq] ?? Date(timeIntervalSince1970: 0), now: now, timeZone: timeZone)
        }
        let titles = try await runBook().records.mapValues { RunSummary($0).title }
        func entry(_ note: MemorySummary) -> KnowledgeView.Note {
            KnowledgeView.Note(
                note: note,
                provenance: Self.provenance(
                    note, runTitle: note.run.flatMap { titles[RunID(unchecked: $0)] }),
                time: time(note.seq))
        }
        let notes = try await memory(steward: steward).reversed().map(entry)
        let shared = try await sharedMemory().reversed().map(entry)
        var routines: [KnowledgeView.Routine] = []
        for routine in try await self.routines(steward: steward) {
            let proposed = try await routineHistory(steward: steward, name: routine.name)
                .filter { $0.kind == "proposed" }
            var versions: [KnowledgeView.RoutineVersion] = []
            for item in proposed.reversed() {
                guard
                    let detail = try await self.routine(
                        steward: steward, name: routine.name, version: item.version)
                else { continue }
                versions.append(
                    .init(
                        version: item.version, summary: detail.summary, gate: detail.gate,
                        approval: Self.approvalText(detail.gate), time: time(item.seq)))
            }
            routines.append(.init(routine: routine, versions: versions))
        }
        return KnowledgeView(
            steward: id.rawValue, notes: Array(notes), shared: Array(shared), routines: routines)
    }

    static func review(_ item: CaseReport) -> ImproveView.CaseReview {
        let sample = item.samples.first
        return ImproveView.CaseReview(
            caseID: item.caseID.rawValue, input: item.input,
            wouldHave: sample?.text ?? "No result recorded.", expected: item.expectedText,
            diff: sample?.diffText ?? "", score: sample?.score.sentence ?? "",
            passed: item.passed, leak: item.leak, corrections: item.corrections.count)
    }

    static func sentence(_ rehearsal: RehearsalSummary) -> String {
        let name = rehearsal.casebook.isEmpty ? "the casebook" : rehearsal.casebook
        let mean = String(format: "%.2f", rehearsal.meanScore)
        return "Passed \(rehearsal.passed) of \(rehearsal.total) cases on \(name)"
            + " (charter v\(rehearsal.charterVersion)), mean score \(mean)."
    }

    static func gateText(_ proposal: ProposalSummary) -> String {
        switch proposal.status {
        case "accepted": return "Accepted."
        case "rejected": return "Rejected."
        case "overridden": return "Accepted by override."
        default: break
        }
        guard let verdict = proposal.verdict else { return "Not checked yet." }
        let candidate = String(format: "%.2f", verdict.candidateMean)
        let against = verdict.baselineMean.map { " against " + String(format: "%.2f", $0) } ?? ""
        let regressions =
            verdict.regressions.isEmpty
            ? "" : "; regressed \(verdict.regressions.joined(separator: ", "))"
        return (verdict.passed ? "Passed the gate" : "Failed the gate")
            + ": mean \(candidate)\(against)\(regressions)."
    }

    static func provenance(_ note: MemorySummary, runTitle: String?) -> String {
        let who =
            switch note.author {
            case "human:local", "local": "you"
            case let author where author.hasPrefix("human:"): String(author.dropFirst(6))
            case let author where author.hasPrefix("steward:"): "the steward"
            default: note.author
            }
        if let about = note.about {
            let name = String(about.dropFirst("person:".count))
            let scope = note.shared ? "every steward" : "this steward"
            return who == "you"
                ? "\(name)'s preference, added by you for \(scope)."
                : "\(name)'s preference, added by \(who) for \(scope)."
        }
        if note.shared {
            return who == "you"
                ? "Shared with every steward by you." : "Shared with every steward by \(who)."
        }
        if let caseID = note.caseID {
            return who == "you"
                ? "From your correction to case \(caseID)."
                : "From a correction to case \(caseID) by \(who)."
        }
        if let runTitle, !runTitle.isEmpty { return "Learned in run \(runTitle)." }
        if note.run != nil { return "Learned in a run." }
        return who == "you" ? "Added by you." : "Added by \(who)."
    }

    static func approvalText(_ gate: RoutineDetail.GateStatus) -> String {
        switch gate {
        case .live: "Live"
        case .pending: "Waiting for approval"
        case .superseded: "Replaced by a newer version"
        }
    }
}
