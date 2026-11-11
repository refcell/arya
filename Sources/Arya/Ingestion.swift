import AryaAdapters
import AryaCore
import AryaEval
import AryaRuntime
import Foundation

// History ingestion (M3.6 #2): a steward reads each connected system's past records through
// the binding `history` tool, page by page from a stored cursor, so a later pass reads only
// what arrived since (incremental) and a failed pass resumes where it stopped. Records are
// deduplicated by their source id. Each pass is one `history.ingested` event: the new ids, the
// counts, the cursor, and any error. The first pass that reads records writes one memory note
// about the source, and onboarding counts a system with records as read. Turning records into
// casebook cases stays the explicit `importHistory` step.

/// Event types for history ingestion.
public enum IngestionEventType {
    public static let ingested = "history.ingested"
}

/// Where a connection's history stands for one steward.
public struct IngestionStatus: Sendable, Hashable, Codable {
    public var steward: String
    /// The binding id (`inbox`).
    public var connection: String
    /// Distinct records read so far, over every pass.
    public var records: Int
    /// Passes recorded.
    public var passes: Int
    /// New records the last pass read.
    public var lastAdded: Int
    /// The cursor the next pass starts from; nil before the first pass.
    public var cursor: String?
    /// True when the last pass reached the end of the history.
    public var complete: Bool
    /// The last pass's error, if it stopped on one (it resumes from `cursor`).
    public var lastError: String?
    /// When the last pass ran.
    public var lastAt: Date?
    /// The oldest and newest record times read (RFC 3339).
    public var oldest: String?
    public var newest: String?
    /// One line, shown verbatim: `inbox: 48 records (Sep 2 to Oct 14), up to date.`
    public var line: String
}

/// One page of a connection's history.
public struct HistoryPage: Sendable {
    public var items: [HistoryItem]
    public var invalid: [String]
    public var next: String?

    public init(items: [HistoryItem], invalid: [String] = [], next: String? = nil) {
        self.items = items
        self.invalid = invalid
        self.next = next
    }
}

/// Reads one connection's history pages; closed after the pass.
public protocol HistoryPageReader: Sendable {
    func page(cursor: String?, limit: Int) async throws -> HistoryPage
    func close() async
}

/// Opens a reader for a steward's binding.
public protocol HistoryPages: Sendable {
    func open(_ binding: CharterBinding, steward: StewardID) async throws -> any HistoryPageReader
}

/// The binding's own process, called for its `history` tool.
struct ProcessHistoryPages: HistoryPages {
    func open(_ binding: CharterBinding, steward: StewardID) async throws
        -> any HistoryPageReader
    {
        guard let command = binding.command else {
            throw WorkspaceError.rejected("binding \(binding.id) has no command")
        }
        let upstream: ProcessToolUpstream
        do {
            upstream = try ProcessToolUpstream(command: command, args: binding.args)
        } catch {
            throw WorkspaceError.rejected("binding \(binding.id) could not start \(command)")
        }
        return Reader(upstream: upstream)
    }

    struct Reader: HistoryPageReader {
        let upstream: ProcessToolUpstream
        func page(cursor: String?, limit: Int) async throws -> HistoryPage {
            var arguments: [String: JSONValue] = ["limit": .int(Int64(limit))]
            if let cursor { arguments["cursor"] = .string(cursor) }
            let read = HistorySource.page(
                toolResult: try await upstream.call(
                    BindingHistory.tool, arguments: .object(arguments)))
            return HistoryPage(items: read.items, invalid: read.invalid, next: read.next)
        }
        func close() async { await upstream.close() }
    }
}

/// History held in memory by binding id, served as the `history` tool pages it (offset
/// cursors), only records up to `now()`: for tools that seed demo homes, whose bindings have
/// no process.
public struct MemoryHistoryPages: HistoryPages {
    let items: [String: [HistoryItem]]
    let now: @Sendable () -> String

    /// `items` by binding id (`inbox`) or `steward/binding` (which wins); `now` is the RFC 3339
    /// time records must not be newer than.
    public init(items: [String: [HistoryItem]], now: @escaping @Sendable () -> String) {
        self.items = items
        self.now = now
    }

    public func open(_ binding: CharterBinding, steward: StewardID) async throws
        -> any HistoryPageReader
    {
        guard let list = items["\(steward.rawValue)/\(binding.id)"] ?? items[binding.id] else {
            throw WorkspaceError.rejected("binding \(binding.id) serves no history")
        }
        return Reader(items: list, until: now())
    }

    struct Reader: HistoryPageReader {
        let items: [HistoryItem]
        let until: String
        func page(cursor: String?, limit: Int) async throws -> HistoryPage {
            let page = BindingHistory.page(
                items, HistoryListParams(until: until, cursor: cursor, limit: limit))
            return HistoryPage(items: page.items, next: page.next)
        }
        func close() async {}
    }
}

extension Workspace {
    /// Serves history from `pages` instead of each binding's process (seeding, tests).
    public func useHistoryPages(_ pages: any HistoryPages) {
        historyPages = pages
    }

    /// Reads `binding`'s history for `steward` from its stored cursor: up to `maxPages` pages
    /// of `pageSize`, new records only (by source id), and records the pass. A failed page
    /// stops the pass, keeps what it read, and leaves the cursor at the last good page, so the
    /// next pass resumes there. Returns the connection's status after the pass.
    @discardableResult
    public func ingestHistory(
        steward: String, binding: String, maxPages: Int = 20, pageSize: Int = 100,
        by person: String = "local"
    ) async throws -> IngestionStatus {
        let record = try await existing(steward)
        guard let found = record.charter.bindings.first(where: { $0.id == binding }),
            found.kind == .mcp
        else { throw WorkspaceError.notFound("binding \(binding)") }
        let before = try ingestionState(record.id)[binding]
        var seen = before?.ids ?? []
        var cursor = before?.cursor
        var fresh: [HistoryItem] = []
        var invalid = 0
        var read = 0
        var complete = false
        var failure: String?
        let size = min(max(pageSize, 1), BindingHistory.maxLimit)
        do {
            let reader = try await historyPages.open(found, steward: record.id)
            do {
                for _ in 0..<max(1, maxPages) {
                    let page = try await reader.page(cursor: cursor, limit: size)
                    read += page.items.count
                    invalid += page.invalid.count
                    for item in page.items where seen.insert(item.id).inserted {
                        fresh.append(item)
                    }
                    // On the last page the cursor stays put, so the next pass rereads it and
                    // picks up records added after it (the ids already read are skipped).
                    guard let next = page.next, next != cursor else {
                        complete = true
                        break
                    }
                    cursor = next
                }
            } catch {
                failure =
                    "\(binding).\(BindingHistory.tool) failed: \(Self.plain(error))"
                    + (found.command.map { " (\($0))" } ?? "")
            }
            await reader.close()
        } catch {
            failure = Self.plain(error)
        }
        let times = fresh.map(\.at).sorted()
        var payload: [String: JSONValue] = [
            "connection": .string(binding), "tool": .string(BindingHistory.tool),
            "ids": .array(fresh.map { .string($0.id) }), "read": .int(Int64(read)),
            "added": .int(Int64(fresh.count)), "invalid": .int(Int64(invalid)),
            "complete": .bool(complete),
        ]
        if let cursor { payload["cursor"] = .string(cursor) }
        if let failure { payload["error"] = .string(failure) }
        if let first = times.first, let last = times.last {
            payload["oldest"] = .string(first)
            payload["newest"] = .string(last)
        }
        _ = try await sink.append(
            RuntimeEventDraft(
                type: IngestionEventType.ingested, steward: record.id, run: nil,
                actor: .person(person), payload: .object(payload)))
        if (before?.ids.isEmpty ?? true), !fresh.isEmpty {
            _ = try await remember(
                Self.historyNote(binding, fresh), steward: steward, tags: ["history"],
                by: person)
        }
        return try await ingestion(steward: steward).first { $0.connection == binding }
            ?? Self.status(steward, binding, nil)
    }

    /// Reads every connection of `steward` that serves history; returns their statuses.
    public func ingestHistory(steward: String, by person: String = "local") async throws
        -> [IngestionStatus]
    {
        let record = try await existing(steward)
        for binding in record.charter.bindings where binding.kind == .mcp {
            _ = try await ingestHistory(steward: steward, binding: binding.id, by: person)
        }
        return try await ingestion(steward: steward)
    }

    /// Where each of `steward`'s connections stands: records read, the cursor, the last error.
    public func ingestion(steward: String) async throws -> [IngestionStatus] {
        let record = try await existing(steward)
        let state = try ingestionState(record.id)
        return record.charter.bindings.filter { $0.kind == .mcp }.map {
            Self.status(steward, $0.id, state[$0.id])
        }
    }

    /// Every steward's connections, by steward then connection.
    public func ingestion() async throws -> [IngestionStatus] {
        var out: [IngestionStatus] = []
        for steward in try await stewards() {
            out += try await ingestion(steward: steward.id)
        }
        return out
    }

    struct IngestionFold {
        var ids: Set<String> = []
        var passes = 0
        var lastAdded = 0
        var cursor: String?
        var complete = false
        var lastError: String?
        var lastAt: Date?
        var oldest: String?
        var newest: String?
    }

    nonisolated func ingestionState(_ steward: StewardID) throws -> [String: IngestionFold] {
        var out: [String: IngestionFold] = [:]
        for event in try facadeState().bySteward[steward] ?? []
        where event.type == IngestionEventType.ingested {
            let payload = event.payload
            guard let connection = payload["connection"]?.stringValue else { continue }
            var fold = out[connection] ?? IngestionFold()
            let ids = (payload["ids"]?.arrayValue ?? []).compactMap(\.stringValue)
            fold.ids.formUnion(ids)
            fold.passes += 1
            fold.lastAdded = ids.count
            fold.cursor = payload["cursor"]?.stringValue ?? fold.cursor
            fold.complete = payload["complete"]?.boolValue ?? false
            fold.lastError = payload["error"]?.stringValue
            fold.lastAt = event.at.date
            if let oldest = payload["oldest"]?.stringValue, oldest < (fold.oldest ?? "~") {
                fold.oldest = oldest
            }
            if let newest = payload["newest"]?.stringValue, newest > (fold.newest ?? "") {
                fold.newest = newest
            }
            out[connection] = fold
        }
        return out
    }

    static func status(_ steward: String, _ connection: String, _ fold: IngestionFold?)
        -> IngestionStatus
    {
        guard let fold else {
            return IngestionStatus(
                steward: steward, connection: connection, records: 0, passes: 0, lastAdded: 0,
                complete: false, line: "\(connection): history not read yet.")
        }
        var line = "\(connection): \(count(fold.ids.count, "record", "records"))"
        if let oldest = fold.oldest, let newest = fold.newest {
            line += " (\(day(oldest)) to \(day(newest)))"
        }
        if let error = fold.lastError {
            line += "; the last pass stopped: \(error)"
        } else {
            line += fold.complete ? ", up to date" : ", more to read"
        }
        return IngestionStatus(
            steward: steward, connection: connection, records: fold.ids.count,
            passes: fold.passes, lastAdded: fold.lastAdded, cursor: fold.cursor,
            complete: fold.complete, lastError: fold.lastError, lastAt: fold.lastAt,
            oldest: fold.oldest, newest: fold.newest, line: line + ".")
    }

    /// An error in words: an RPC error's message, else its description.
    static func plain(_ error: any Error) -> String {
        if let rpc = error as? RPCError { return rpc.message }
        return "\(error)"
    }

    /// `Sep 2` from an RFC 3339 time (UTC date).
    static func day(_ time: String) -> String {
        let parts = time.prefix(10).split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let date = Int(parts[2]),
            (1...12).contains(month)
        else { return String(time.prefix(10)) }
        let names = [
            "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        ]
        return "\(names[month - 1]) \(date)"
    }

    /// The note the first pass writes: how much, over when, and the usual choice.
    static func historyNote(_ binding: String, _ items: [HistoryItem]) -> String {
        let times = items.map(\.at).sorted()
        var text = "Read \(count(items.count, "past record", "past records")) from \(binding)"
        if let first = times.first, let last = times.last {
            text += " (\(day(first)) to \(day(last)))"
        }
        let choices = Dictionary(grouping: items.compactMap(\.choice), by: { $0 })
            .mapValues(\.count)
        if let top = choices.max(by: {
            $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key
        }
        ) {
            text += "; people chose \(top.key) most often (\(top.value) of \(items.count))"
        }
        return text + "."
    }
}
