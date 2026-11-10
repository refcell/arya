import AryaCore
import AryaRuntime
import Foundation

/// One past item from a connected system and what a person did with it. A binding's history
/// tool returns `{items: [...]}`; an export file holds one item per line.
///
///     {"id":"MSG-110","input":"New message MSG-110: Invoice shows the wrong company name",
///      "did":{"decisions":[{"choice":"billing"}],"actions":[{"kind":"route","target":"…"}]},
///      "by":"person:sam","at":"2026-10-12T09:00:00Z","context":{"toolResults":[…]}}
public struct HistoryItem: Hashable, Sendable, Codable {
    /// The item's id in its system, for example a message or ticket id.
    public var id: String
    /// The input the steward would have seen.
    public var input: String
    /// What the person did, in the shape of a case's expected result.
    public var did: JSONValue
    /// Who did it, for example `person:sam`.
    public var by: String?
    /// When, as the system recorded it (ISO 8601); newest items are kept first.
    public var at: String?
    /// Tool results the steward would have read, served back in rehearsal.
    public var context: CaseContext?

    public init(
        id: String, input: String, did: JSONValue, by: String? = nil, at: String? = nil,
        context: CaseContext? = nil
    ) {
        self.id = id
        self.input = input
        self.did = did
        self.by = by
        self.at = at
        self.context = context
    }
}

/// Reads history items from an export file or a binding tool's result.
public enum HistorySource {
    /// One item per line; blank lines are ignored. A line that is not an item is reported in
    /// `invalid` with its line number instead of failing the read.
    public static func items(jsonLines data: Data) -> (items: [HistoryItem], invalid: [String]) {
        var items: [HistoryItem] = []
        var invalid: [String] = []
        let text = String(decoding: data, as: UTF8.self)
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
        {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let item = try? JSONDecoder().decode(HistoryItem.self, from: Data(trimmed.utf8)) {
                items.append(item)
            } else {
                invalid.append("line \(index + 1): not a history item")
            }
        }
        return (items, invalid)
    }

    /// A tool result: `{items}`, MCP `structuredContent.items`, or the first text content
    /// holding either as JSON.
    public static func items(toolResult: JSONValue) -> (items: [HistoryItem], invalid: [String]) {
        if let list = toolResult["structuredContent"]?["items"] ?? toolResult["items"] {
            return decode(list)
        }
        if let text = toolResult["content"]?[0]?["text"]?.stringValue,
            let value = try? CanonicalJSON.decode(JSONValue.self, from: Data(text.utf8)),
            let list = value["items"]
        {
            return decode(list)
        }
        return ([], ["the history tool returned no items list"])
    }

    static func decode(_ list: JSONValue) -> (items: [HistoryItem], invalid: [String]) {
        var items: [HistoryItem] = []
        var invalid: [String] = []
        for (index, value) in (list.arrayValue ?? []).enumerated() {
            if let data = try? CanonicalJSON.encode(value),
                let item = try? JSONDecoder().decode(HistoryItem.self, from: data)
            {
                items.append(item)
            } else {
                invalid.append("item \(index + 1): not a history item")
            }
        }
        return (items, invalid)
    }
}

/// What a history import did.
public struct HistoryImportResult: Hashable, Sendable {
    /// The new casebook version; `nil` when nothing was added.
    public var casebook: Casebook?
    public var added: [CaseID]
    /// Item ids already in the casebook (same id or same input).
    public var duplicates: [String]
    /// Items left out, with why (`MSG-9: empty input`).
    public var invalid: [String]
    /// Valid new items left out by the size cap.
    public var overCap: Int
    /// One line, shown verbatim: `Added 12 cases from inbox.history; 3 already in the
    /// casebook, 1 invalid, 5 over the cap of 12.`
    public var summary: String
}

/// Turns history items into casebook cases (`hist-<item id>`) with provenance, skipping items
/// already in the casebook, and records the grown casebook as a new version.
public struct HistoryImporter: Sendable {
    public var sink: any EventSink
    public var blobs: any EvalBlobStore
    /// Largest input accepted, in characters.
    public static let maxInput = 4000

    public init(sink: any EventSink, blobs: any EvalBlobStore) {
        self.sink = sink
        self.blobs = blobs
    }

    /// Adds at most `limit` new cases, newest first by `at`, to `book` (or a new casebook
    /// named `name`). `source` names where the items came from (`inbox.history`, a file name).
    public func importHistory(
        _ items: [HistoryItem], invalid alreadyInvalid: [String] = [], into book: Casebook?,
        name: String, steward: StewardID, source: String, limit: Int = 200,
        actor: RuntimeActor = .localUser
    ) async throws -> HistoryImportResult {
        let plan = try Self.plan(
            items, into: book, source: source, limit: limit, invalid: alreadyInvalid)
        guard !plan.cases.isEmpty else {
            return HistoryImportResult(
                casebook: nil, added: [], duplicates: plan.duplicates, invalid: plan.invalid,
                overCap: plan.overCap, summary: plan.summary(source, limit))
        }
        var next = try book ?? Casebook(name: name, cases: [])
        for item in plan.cases { next = try next.upserting(item) }
        try await CasebookImporter(blobs: blobs, sink: sink).record(
            next, steward: steward, actor: actor, correctedFrom: book?.version)
        return HistoryImportResult(
            casebook: next, added: plan.cases.map(\.id), duplicates: plan.duplicates,
            invalid: plan.invalid, overCap: plan.overCap, summary: plan.summary(source, limit))
    }

    struct Plan {
        var cases: [Case] = []
        var duplicates: [String] = []
        var invalid: [String] = []
        var overCap = 0

        func summary(_ source: String, _ limit: Int) -> String {
            var parts = [
                "Added \(cases.count) \(cases.count == 1 ? "case" : "cases") from \(source)"
            ]
            var extra: [String] = []
            if !duplicates.isEmpty { extra.append("\(duplicates.count) already in the casebook") }
            if !invalid.isEmpty { extra.append("\(invalid.count) invalid") }
            if overCap > 0 { extra.append("\(overCap) over the cap of \(limit)") }
            if !extra.isEmpty { parts.append(extra.joined(separator: ", ")) }
            return parts.joined(separator: "; ") + "."
        }
    }

    /// Validates, dedupes, orders, and caps the items, without recording anything.
    static func plan(
        _ items: [HistoryItem], into book: Casebook?, source: String, limit: Int,
        invalid: [String]
    ) throws -> Plan {
        var plan = Plan(invalid: invalid)
        var ids = Set(book?.cases.map(\.id) ?? [])
        var inputs = Set(book?.cases.map { normalized($0.input.text) } ?? [])
        // Newest first; items without a time keep their order after timed ones.
        let ordered = items.enumerated().sorted { a, b in
            switch (a.element.at, b.element.at) {
            case (let x?, let y?) where x != y: return x > y
            case (.some, .none): return true
            case (.none, .some): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
        var fresh: [Case] = []
        for item in ordered {
            let id = item.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let input = item.input.trimmingCharacters(in: .whitespacesAndNewlines)
            if let reason = problem(id: id, input: input, did: item.did) {
                plan.invalid.append("\(id.isEmpty ? "?" : id): \(reason)")
                continue
            }
            guard let caseID = CaseID(rawValue: "hist-\(id)") else {
                plan.invalid.append("\(id): id has characters a case id cannot hold")
                continue
            }
            guard !ids.contains(caseID), !inputs.contains(normalized(input)) else {
                plan.duplicates.append(id)
                continue
            }
            ids.insert(caseID)
            inputs.insert(normalized(input))
            let who = item.by.map { " by \($0)" } ?? ""
            let when = item.at.map { " at \($0)" } ?? ""
            fresh.append(
                Case(
                    id: caseID, input: CaseInput(text: input),
                    context: item.context ?? CaseContext(), expected: item.did,
                    source: "history \(source) item \(id)\(who)\(when)"))
        }
        let cap = max(0, limit)
        plan.cases = Array(fresh.prefix(cap))
        plan.overCap = max(0, fresh.count - cap)
        return plan
    }

    static func problem(id: String, input: String, did: JSONValue) -> String? {
        if id.isEmpty { return "missing id" }
        if input.isEmpty { return "empty input" }
        if input.count > maxInput { return "input longer than \(maxInput) characters" }
        guard case .object(let fields) = did, !fields.isEmpty else {
            return "no record of what the person did"
        }
        return nil
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
