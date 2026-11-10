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
        let readiness = try await ReadinessReports(sink: readSink).report(record.id)
        var historyCases = 0
        if let newest = try await casebookIndex().last(where: { $0.steward == steward }) {
            let book = try await casebookSource.casebook(version: newest.version)
            historyCases = book.cases.filter { $0.id.rawValue.hasPrefix("hist-") }.count
        }

        let systems = context.connections.filter { $0.toolCalls > 0 || $0.actionsExecuted > 0 }
        let people = context.people.map(\.id)
        let notes = Set(
            context.people.flatMap(\.notes) + context.connections.flatMap(\.notes))
        let contextNotes = notes.count
        func list(_ names: [String]) -> String {
            names.isEmpty
                ? ""
                : ": " + names.prefix(4).joined(separator: ", ")
                    + (names.count > 4 ? ", and \(names.count - 4) more" : "")
        }
        let total = context.connections.count
        let steps: [OnboardingState.Step] = [
            .init(
                key: "systems", title: "Read its systems", done: total > 0 && !systems.isEmpty,
                count: systems.count, total: total,
                detail: total == 0
                    ? "No systems connected yet."
                    : "Read \(systems.count) of \(total) "
                        + "\(total == 1 ? "system" : "systems")\(list(systems.map(\.id)))."),
            .init(
                key: "people", title: "Find its people", done: !people.isEmpty,
                count: people.count, total: nil,
                detail: people.isEmpty
                    ? "No people found yet."
                    : "Knows \(Self.count(people.count, "person", "people"))\(list(people))."),
            .init(
                key: "processes", title: "Learn its processes", done: !routines.isEmpty,
                count: routines.count, total: nil,
                detail: routines.isEmpty
                    ? "No routines learned yet."
                    : "Learned \(Self.count(routines.count, "routine", "routines"))"
                        + "\(list(routines.map(\.name)))."),
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
                detail: historyCases == 0
                    ? "No history imported yet."
                    : "Imported \(Self.count(historyCases, "case", "cases")) from history."),
            .init(
                key: "review", title: "Review what it would do",
                done: (review?.total ?? 0) > 0 && review?.reviewed == review?.total,
                count: review?.reviewed ?? 0, total: review?.total,
                detail: review.map(\.progressText) ?? "Nothing to review yet."),
            .init(
                key: "ready", title: "Ready to go live", done: readiness.ready,
                count: readiness.ready ? 1 : 0, total: 1, detail: readiness.summary),
        ]
        let done = steps.filter(\.done).count
        let next = steps.first { !$0.done }
        return OnboardingState(
            steward: record.id.rawValue, steps: steps, done: done,
            progress: Double(done) / Double(steps.count), next: next,
            systems: systems.map(\.id), people: people, processes: routines.map(\.name),
            contextNotes: contextNotes, historyCases: historyCases, review: review,
            ready: readiness.ready,
            summary: next.map {
                "\(done) of \(steps.count) steps done; next: \($0.title.lowercased())."
            } ?? "Onboarded: all \(steps.count) steps done.")
    }

    static func count(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n) \(n == 1 ? one : many)"
    }
}
