import AryaAdapters
import AryaCore
import AryaEval
import AryaRuntime
import Foundation

/// What a history import did, for the CLI and app.
public struct HistoryImportSummary: Sendable, Hashable, Codable {
    public var steward: String
    /// The casebook the cases went into, and its new version (unchanged when nothing was
    /// added).
    public var casebook: String
    public var version: String?
    public var added: [String]
    public var duplicates: [String]
    public var invalid: [String]
    public var overCap: Int
    /// One line, shown verbatim.
    public var summary: String
}

extension Workspace {
    /// Adds past items from an export file in the binding `history` shape
    /// (`{"v":1,"history":[…]}`) to the steward's newest casebook, or a new casebook named
    /// `history`, as cases with provenance. At most `limit` new cases, newest first; items
    /// already in the casebook are skipped. `binding` names the binding the records came from
    /// (default: the charter's first binding that reads `get`, else its first with any read),
    /// so rehearsal serves each record as that binding's `get` read, or its first other read.
    public func importHistory(
        steward: String, data: Data, source: String, binding: String? = nil, limit: Int = 200,
        by person: String = "local"
    ) async throws -> HistoryImportSummary {
        let record = try await existing(steward)
        let read = HistorySource.items(export: data)
        let mcp = record.charter.bindings.filter { $0.kind == .mcp }
        let found =
            binding.map { name in mcp.first { $0.id == name } }
            ?? mcp.first { $0.read.contains("get") } ?? mcp.first { Self.recordRead($0) != nil }
        if let binding, found == nil { throw WorkspaceError.notFound("binding \(binding)") }
        return try await importHistory(
            steward: steward, items: read.items, invalid: read.invalid, source: source,
            binding: found.flatMap(Self.recordTool), limit: limit, person: person)
    }

    /// The read a history record answers: `get` when the binding has it, else its first read
    /// other than the history tool (a refunds binding's `order`).
    static func recordRead(_ binding: CharterBinding) -> String? {
        binding.read.contains("get")
            ? "get" : binding.read.first { $0 != BindingHistory.tool }
    }

    /// `<binding>.<read>` for `recordRead`, or nil when the binding reads nothing else.
    static func recordTool(_ binding: CharterBinding) -> String? {
        recordRead(binding).map { "\(binding.id).\($0)" }
    }

    /// Pages through a binding's `history` tool (`{limit, cursor}` in, `{items, next}` out) and
    /// imports the items as `importHistory(steward:data:source:binding:limit:)` does. The tool
    /// must be one of the binding's `read` tools.
    public func importHistory(
        steward: String, binding: String, tool: String = BindingHistory.tool, limit: Int = 200,
        by person: String = "local"
    ) async throws -> HistoryImportSummary {
        let record = try await existing(steward)
        guard let found = record.charter.bindings.first(where: { $0.id == binding }),
            found.kind == .mcp, let command = found.command
        else { throw WorkspaceError.notFound("binding \(binding)") }
        guard found.read.contains(tool) else {
            throw WorkspaceError.rejected("\(binding).\(tool) is not one of the binding's reads")
        }
        let upstream: ProcessToolUpstream
        do {
            upstream = try ProcessToolUpstream(command: command, args: found.args)
        } catch {
            throw WorkspaceError.unavailable("binding \(binding) (\(command))")
        }
        var items: [HistoryItem] = []
        var invalid: [String] = []
        var cursor: String?
        do {
            // Every page, oldest first, so the newest `limit` can be kept; at most 20 pages.
            for _ in 0..<20 {
                var arguments: [String: JSONValue] = [
                    "limit": .int(Int64(BindingHistory.maxLimit))
                ]
                if let cursor { arguments["cursor"] = .string(cursor) }
                let page = HistorySource.page(
                    toolResult: try await upstream.call(tool, arguments: .object(arguments)))
                items += page.items
                invalid += page.invalid
                guard let next = page.next, next != cursor else { break }
                cursor = next
            }
            await upstream.close()
        } catch {
            await upstream.close()
            throw WorkspaceError.rejected("\(binding).\(tool) failed: \(error)")
        }
        return try await importHistory(
            steward: steward, items: items, invalid: invalid, source: "\(binding).\(tool)",
            binding: Self.recordTool(found), limit: limit, person: person)
    }

    private func importHistory(
        steward: String, items: [HistoryItem], invalid: [String], source: String,
        binding: String?, limit: Int, person: String
    ) async throws -> HistoryImportSummary {
        let id = try await existing(steward).id
        let newest = try await casebookIndex().last { $0.steward == steward }
        var book: Casebook?
        if let newest { book = try await casebookSource.casebook(version: newest.version) }
        let result: HistoryImportResult
        do {
            result = try await HistoryImporter(sink: sink, blobs: blobs).importHistory(
                items, invalid: invalid, into: book, name: book?.name ?? "history",
                steward: id, source: source, binding: binding, limit: limit,
                actor: .person(person))
        } catch let error as CaseError {
            throw WorkspaceError.rejected("history: \(error)")
        }
        return HistoryImportSummary(
            steward: steward, casebook: result.casebook?.name ?? book?.name ?? "history",
            version: result.casebook?.version ?? book?.version,
            added: result.added.map(\.rawValue), duplicates: result.duplicates,
            invalid: result.invalid, overCap: result.overCap, summary: result.summary)
    }

    /// The review queue on the steward's newest casebook: what it would have done next to what
    /// the person did, case by case, with progress. `nil` when the steward has no casebook.
    public func reviewQueue(steward: String) async throws -> ReviewQueueSummary? {
        try await ReviewQueue(sink: readSink, casebooks: casebookSource)
            .view(steward: try await existing(steward).id)
    }

    /// Records a person's review of a case in the steward's newest casebook: `agree` or
    /// `skip`. To correct a case, use `correct(steward:case:expected:note:)`.
    public func reviewCase(
        steward: String, case caseID: String, verdict: String, by person: String = "local"
    ) async throws -> ReviewQueueSummary? {
        let id = try await existing(steward).id
        let parsed: CaseReviewedPayload.Verdict
        switch verdict {
        case "agree", "agreed": parsed = .agreed
        case "skip", "skipped": parsed = .skipped
        default: throw WorkspaceError.rejected("verdict must be agree or skip, not \(verdict)")
        }
        guard let wanted = CaseID(rawValue: caseID) else {
            throw WorkspaceError.notFound(caseID)
        }
        let book = try await casebook(for: steward, version: nil)
        let queue = ReviewQueue(sink: readSink, casebooks: casebookSource)
        do {
            try await queue.record(
                parsed, caseID: wanted, casebook: book, steward: id, person: person)
        } catch EvalError.unknownCase {
            throw WorkspaceError.notFound(caseID)
        }
        return try await queue.view(steward: id)
    }
}

/// The review queue as the CLI and app read it.
public typealias ReviewQueueSummary = ReviewQueueView
/// One case in the review queue.
public typealias ReviewQueueItem = ReviewItem
/// Where a case stands in the review queue.
public typealias ReviewQueueStatus = ReviewStatus
