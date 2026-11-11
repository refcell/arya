import AryaCore
import AryaEval
import Foundation

/// How far a steward has come in learning its job before it goes live: the systems it has
/// read, the people and processes it found, the context notes it wrote, the history it
/// imported, the person's review of that history, and readiness. One step each, in order.
public struct OnboardingState: Sendable, Hashable, Codable {
    /// One onboarding step.
    public struct Step: Sendable, Hashable, Codable {
        /// `systems`, `people`, `processes`, `notes`, `history`, `review`, or `ready`.
        public var key: String
        public var title: String
        public var done: Bool
        /// What the step counted (systems read, people found, cases reviewed, ...).
        public var count: Int
        /// Out of how many, when the step has a total.
        public var total: Int?
        /// One line, shown verbatim: `Read 2 of 3 systems: inbox, calendar.`
        public var detail: String
    }

    public var steward: String
    public var steps: [Step]
    public var done: Int
    /// 0...1: finished steps over all steps.
    public var progress: Double
    /// The first step not done; nil once onboarded.
    public var next: Step?
    /// Connections it has used.
    public var systems: [String]
    /// People it knows, by id.
    public var people: [String]
    /// Routines it learned, by name.
    public var processes: [String]
    /// Live memory notes about the steward's people and systems.
    public var contextNotes: Int
    /// Cases imported from history in the newest casebook.
    public var historyCases: Int
    /// The review queue on the newest casebook, if there is one.
    public var review: ReviewQueueSummary?
    public var ready: Bool
    /// One line, shown verbatim: `4 of 7 steps done; next: import history.`
    public var summary: String
    /// The latest onboard run (runtime): what it read from directory and process bindings;
    /// nil before one ran or in older summaries.
    public var onboard: OnboardSummary?
    /// Eval's go-live gate behind the `ready` step; nil in older summaries.
    public var goLive: GoLiveSummary?
    /// History read from each connection: records, cursor, last error; nil in older summaries.
    public var ingestion: [IngestionStatus]? = nil
}

extension Workspace {
    /// The steward's onboarding: what it has read, found, written, imported, had reviewed,
    /// and whether it is ready, from the context, memory, casebooks, review queue, and
    /// readiness reads.
    public func onboardingState(steward: String) async throws -> OnboardingState {
        let record = try await existing(steward)
        let context = try await self.context(steward: steward)
        let routines = try await self.routines(steward: steward)
        let review = try await reviewQueue(steward: steward)
        let onboard = try await onboarding(steward: steward)
        let gate = try await goLiveGate(steward: steward)
        var historyCases = 0
        if let newest = try await casebookIndex().last(where: { $0.steward == steward }) {
            let book = try await casebookSource.casebook(version: newest.version)
            historyCases = book.cases.filter { $0.id.rawValue.hasPrefix("hist-") }.count
        }

        // Systems it used in runs, plus those the onboard run read without error.
        let used = context.connections.filter { $0.toolCalls > 0 || $0.actionsExecuted > 0 }
            .map(\.id)
        // ... and those whose history it has read.
        let ingestion = try await self.ingestion(steward: steward)
        let ingested = ingestion.filter { $0.records > 0 }.map(\.connection)
        let known = used + (onboard?.sources ?? []).filter { !used.contains($0) }
        let systems = known + ingested.filter { !known.contains($0) }
        let people = context.people.map(\.id)
        let peopleFound = max(people.count, onboard?.people ?? 0)
        let notes = Set(
            context.people.flatMap(\.notes) + context.connections.flatMap(\.notes))
        // Notes about its people and systems, plus the notes the onboard run wrote (each with
        // the onboard run as its provenance).
        let contextNotes = notes.count + (onboard?.notes ?? 0)
        let found = onboard.map { ($0.queues, $0.rules, $0.documents) } ?? (0, 0, 0)
        var foundParts: [String] = []
        if found.0 > 0 { foundParts.append(Self.count(found.0, "queue", "queues")) }
        if found.1 > 0 { foundParts.append(Self.count(found.1, "rule", "rules")) }
        if found.2 > 0 { foundParts.append(Self.count(found.2, "document", "documents")) }
        let processCount = routines.count + found.0 + found.1 + found.2
        func list(_ names: [String]) -> String {
            names.isEmpty
                ? ""
                : ": " + names.prefix(4).joined(separator: ", ")
                    + (names.count > 4 ? ", and \(names.count - 4) more" : "")
        }
        let total = max(context.connections.count, systems.count)
        let records = ingestion.reduce(0) { $0 + $1.records }
        let historyRead =
            records == 0
            ? ""
            : " Read \(Self.count(records, "past record", "past records")) from "
                + "\(Self.count(ingested.count, "system", "systems"))."
        let steps: [OnboardingState.Step] = [
            .init(
                key: "systems", title: "Read its systems", done: total > 0 && !systems.isEmpty,
                count: systems.count, total: total,
                detail: total == 0
                    ? "No systems connected yet."
                    : "Read \(systems.count) of \(total) "
                        + "\(total == 1 ? "system" : "systems")\(list(systems))."),
            .init(
                key: "people", title: "Find its people", done: peopleFound > 0,
                count: peopleFound, total: nil,
                detail: peopleFound == 0
                    ? "No people found yet."
                    : "Knows \(Self.count(peopleFound, "person", "people"))\(list(people))."),
            .init(
                key: "processes", title: "Learn its processes", done: processCount > 0,
                count: processCount, total: nil,
                detail: processCount == 0
                    ? "No routines or processes found yet."
                    : ([
                        routines.isEmpty
                            ? nil
                            : "Learned \(Self.count(routines.count, "routine", "routines"))"
                                + list(routines.map(\.name)),
                        foundParts.isEmpty ? nil : "found " + foundParts.joined(separator: ", "),
                    ].compactMap { $0 }.joined(separator: "; ").capitalizedFirst) + "."),
            .init(
                key: "notes", title: "Write context notes", done: contextNotes > 0,
                count: contextNotes, total: nil,
                detail: contextNotes == 0
                    ? "No notes about its people or systems yet."
                    : "Wrote \(Self.count(contextNotes, "note", "notes")) about its people "
                        + "and systems."),
            .init(
                key: "history", title: "Import history", done: historyCases > 0,
                count: historyCases, total: nil,
                detail: (historyCases == 0
                    ? "No history imported yet."
                    : "Imported \(Self.count(historyCases, "case", "cases")) from history.")
                    + historyRead),
            .init(
                key: "review", title: "Review what it would do",
                done: (review?.total ?? 0) > 0 && review?.reviewed == review?.total,
                count: review?.reviewed ?? 0, total: review?.total,
                detail: review.map(\.progressText) ?? "Nothing to review yet."),
            .init(
                key: "ready", title: "Ready to go live", done: gate.ready,
                count: gate.conditions.filter(\.met).count, total: gate.conditions.count,
                detail: gate.summary),
        ]
        let done = steps.filter(\.done).count
        let next = steps.first { !$0.done }
        return OnboardingState(
            steward: record.id.rawValue, steps: steps, done: done,
            progress: Double(done) / Double(steps.count), next: next,
            systems: systems, people: people, processes: routines.map(\.name),
            contextNotes: contextNotes, historyCases: historyCases, review: review,
            ready: gate.ready,
            summary: next.map {
                "\(done) of \(steps.count) steps done; next: \($0.title.lowercased())."
            } ?? "Onboarded: all \(steps.count) steps done.", onboard: onboard, goLive: gate,
            ingestion: ingestion)
    }

    static func count(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n) \(n == 1 ? one : many)"
    }
}

extension String {
    fileprivate var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
