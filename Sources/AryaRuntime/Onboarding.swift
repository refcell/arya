import AryaAdapters
import AryaCore
import AryaLedger
import AryaMemory
import Foundation

// Self-onboarding (decision 0059). A new steward learns how the work is organized today before
// it acts: an onboard run reads each MCP binding that lists the `directory` or `process` read
// tool and keeps what they say as memory notes: people and their roles and queues, queues and
// their owners, routing rules people follow, and the documents that describe the work. Like a
// report run (0050) it is a short run with no adapter: `run.started` (input kind `onboard`),
// one `onboard.read` per tool called (counts, or the error), `memory.added` per new note
// (authored by the steward, with the onboard run as provenance and a `from:<binding>` tag),
// `onboard.completed`, then `run.finished`. Notes equal to live ones are not added again, so
// onboarding again only adds what changed. It runs before a steward's first live run when the
// engine can connect to bindings, and on request (`arya steward onboard`).

/// Event types of onboarding.
public enum OnboardEventType {
    /// `onboard.read`: one convention tool read from one binding.
    public static let read = EventType("onboard.read")
    /// `onboard.completed`: what an onboard run learned.
    public static let completed = EventType("onboard.completed")
}

/// `onboard.read` (actor: system).
public struct OnboardRead: Sendable, Hashable, Codable {
    public var binding: String
    /// `directory` or `process`.
    public var tool: String
    public var people: Int?
    public var queues: Int?
    public var rules: Int?
    public var documents: Int?
    /// Set when the call failed; the counts are then absent.
    public var error: String?

    public init(
        binding: String, tool: String, people: Int? = nil, queues: Int? = nil,
        rules: Int? = nil, documents: Int? = nil, error: String? = nil
    ) {
        self.binding = binding
        self.tool = tool
        self.people = people
        self.queues = queues
        self.rules = rules
        self.documents = documents
        self.error = error
    }
}

/// `onboard.completed` (actor: system): the onboard run's totals.
public struct OnboardCompleted: Sendable, Hashable, Codable {
    /// Bindings read without error.
    public var sources: [String]
    /// Notes added; `duplicates` were already known.
    public var notes: Int
    public var duplicates: Int
    public var people: Int
    public var queues: Int
    public var rules: Int
    public var documents: Int
    /// Tool calls that failed.
    public var failed: Int

    public init(
        sources: [String] = [], notes: Int = 0, duplicates: Int = 0, people: Int = 0,
        queues: Int = 0, rules: Int = 0, documents: Int = 0, failed: Int = 0
    ) {
        self.sources = sources
        self.notes = notes
        self.duplicates = duplicates
        self.people = people
        self.queues = queues
        self.rules = rules
        self.documents = documents
        self.failed = failed
    }
}

/// How an onboard run ended.
public struct OnboardOutcome: Sendable, Hashable {
    public var run: RunID
    public var completed: OnboardCompleted
}

/// Connects to a binding's MCP server.
public typealias BindingConnect = @Sendable (CharterBinding) async throws -> any ToolUpstream

/// What onboarding reads and how it words notes.
public enum Onboarding {
    /// The convention tools onboarding reads.
    public static let tools = [BindingTools.directory, BindingTools.process]
    /// Longest document text kept in one note.
    public static let documentChars = 1500
    /// The memory tag every onboarding note carries.
    public static let tag = "onboarding"

    /// `charter`'s bindings that onboarding reads, each with the convention tools it lists.
    public static func sources(_ charter: Charter) -> [(CharterBinding, [String])] {
        charter.bindings.compactMap { binding in
            guard binding.kind == .mcp else { return nil }
            let tools = tools.filter { binding.read.contains($0) }
            return tools.isEmpty ? nil : (binding, tools)
        }
    }

    /// The notes for a `directory` result from `binding`.
    public static func notes(_ result: DirectoryListResult, from binding: String)
        -> [ProposedNote]
    {
        result.people.map { person in
            var text = "Person: \(person.name) (\(person.id))"
            if !person.roles.isEmpty { text += ", roles \(person.roles.joined(separator: ", "))" }
            if !person.queues.isEmpty {
                text += "; handles queues \(person.queues.joined(separator: ", "))"
            }
            return ProposedNote(text: text + ".", tags: [tag, "people", "from:\(binding)"])
        }
    }

    /// The notes for a `process` result from `binding`.
    public static func notes(_ result: ProcessListResult, from binding: String)
        -> [ProposedNote]
    {
        let tags = { (kind: String) in [tag, kind, "from:\(binding)"] }
        let queues = result.queues.map { queue in
            var text = "Queue: \(queue.name) (\(queue.id))"
            if let owner = queue.owner { text += ", owned by \(owner)" }
            text += "."
            if let description = queue.description, !description.isEmpty {
                text += " \(description)"
            }
            return ProposedNote(text: text, tags: tags("queues"))
        }
        let rules = result.rules.map { rule in
            var text = "Routing rule: when \(rule.when), \(rule.then.kind)"
            if let target = rule.then.target { text += " \(target)" }
            if let by = rule.then.by { text += " (by \(by))" }
            if let source = rule.source { text += "; written in \(source)" }
            return ProposedNote(text: text + ".", tags: tags("rules"))
        }
        let documents = result.documents.map { document in
            let body = document.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let cut = body.count > documentChars ? String(body.prefix(documentChars)) + "…" : body
            return ProposedNote(
                text: "Document \(document.title) (\(document.id)): \(cut)", tags: tags("documents")
            )
        }
        return queues + rules + documents
    }

    /// The latest `onboard.completed` of `steward`, with its run, or nil if it never onboarded.
    public static func latest(_ steward: StewardID, in events: [RuntimeEvent]) throws
        -> (run: RunID, completed: OnboardCompleted, at: Timestamp)?
    {
        guard
            let event = events.last(where: {
                $0.draft.steward == steward && $0.type == OnboardEventType.completed.rawValue
            }), let run = event.draft.run
        else { return nil }
        return (run, try Payload.decode(OnboardCompleted.self, event.payload), event.at)
    }
}

extension RunEngine {
    /// Runs an onboard run of `steward`: reads every onboarding source and adds what they say
    /// to memory. Returns nil, recording nothing, when the charter has no source.
    @discardableResult
    public func onboard(
        _ steward: StewardID, connect: BindingConnect, actor: RuntimeActor = .system
    ) async throws -> OnboardOutcome? {
        let record = try await StewardLifecycle(sink: sink).book().records[steward]
        guard let record else { throw StewardError.notFound(steward) }
        guard record.status != .retired else { throw RunError.stewardRetired(steward) }
        let sources = Onboarding.sources(record.charter)
        guard !sources.isEmpty else { return nil }
        let run = ambient.newID(RunID.self)
        let lease = try leases.acquire(run)
        defer { lease.release() }
        let names = sources.map(\.0.id).joined(separator: ", ")
        try await append(
            RunEventType.started, steward, run, actor,
            RunStarted(
                input: RunInputRecord(kind: .onboard, text: "Onboard from \(names)."),
                charterVersion: record.version, adapter: record.charter.adapter,
                effort: record.charter.effort, instructions: "", limits: record.charter.limits))
        var totals = OnboardCompleted()
        var proposed: [ProposedNote] = []
        for (binding, tools) in sources {
            var ok = false
            for tool in tools {
                let read = await Self.read(tool, from: binding, connect: connect)
                try await append(OnboardEventType.read.rawValue, steward, run, .system, read.event)
                if read.event.error == nil {
                    ok = true
                    proposed += read.notes
                    totals.people += read.event.people ?? 0
                    totals.queues += read.event.queues ?? 0
                    totals.rules += read.event.rules ?? 0
                    totals.documents += read.event.documents ?? 0
                } else {
                    totals.failed += 1
                }
            }
            if ok { totals.sources.append(binding.id) }
        }
        let live = try await start.current(sink).memory.memory
        let intake = try MemoryIntake.notes(
            proposed, steward: steward, run: run, live: live, ambient: ambient)
        for draft in intake.drafts { _ = try await sink.append(RuntimeEventDraft(draft)) }
        totals.notes = intake.accepted.count
        totals.duplicates = intake.duplicates.count
        try await append(OnboardEventType.completed.rawValue, steward, run, .system, totals)
        if totals.sources.isEmpty {
            try await append(
                RunEventType.failed, steward, run, .system,
                RunFailed(
                    reason: RunFailureReason.adapterFailed.rawValue,
                    detail: "could not read \(names)"))
        } else {
            let learned = "\(totals.notes) notes from \(totals.sources.joined(separator: ", "))"
            try await append(
                RunEventType.finished, steward, run, .system,
                RunFinished(status: .completed, summary: "Onboarded: \(learned)"))
        }
        return OnboardOutcome(run: run, completed: totals)
    }

    /// True when `steward` should onboard before its next live run: it has an onboarding source,
    /// never onboarded, and has no runs yet.
    func needsOnboarding(_ steward: StewardID, charter: Charter) async throws -> Bool {
        guard !Onboarding.sources(charter).isEmpty else { return false }
        let runs = try await sink.book(RunBook.self)
        return !runs.all.contains { $0.steward == steward }
    }

    private static func read(
        _ tool: String, from binding: CharterBinding, connect: BindingConnect
    ) async -> (event: OnboardRead, notes: [ProposedNote]) {
        do {
            let upstream = try await connect(binding)
            let value: JSONValue
            do {
                value = try await upstream.call(tool, arguments: [:])
                await upstream.close()
            } catch {
                await upstream.close()
                throw error
            }
            let content = value["structuredContent"] ?? value
            let data = try CanonicalJSON.encode(content)
            if tool == BindingTools.directory {
                let result = try CanonicalJSON.decode(DirectoryListResult.self, from: data)
                return (
                    OnboardRead(binding: binding.id, tool: tool, people: result.people.count),
                    Onboarding.notes(result, from: binding.id)
                )
            }
            let result = try CanonicalJSON.decode(ProcessListResult.self, from: data)
            return (
                OnboardRead(
                    binding: binding.id, tool: tool, queues: result.queues.count,
                    rules: result.rules.count, documents: result.documents.count),
                Onboarding.notes(result, from: binding.id)
            )
        } catch {
            return (OnboardRead(binding: binding.id, tool: tool, error: "\(error)"), [])
        }
    }

    private func append<P: Encodable>(
        _ type: String, _ steward: StewardID, _ run: RunID, _ actor: RuntimeActor, _ payload: P
    ) async throws {
        _ = try await sink.append(
            RuntimeEventDraft(
                type: type, steward: steward, run: run, actor: actor,
                payload: try Payload.encode(payload)))
    }
}
