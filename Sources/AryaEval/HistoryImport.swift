import AryaAdapters
import AryaCore
import AryaRuntime
import Foundation

/// Reads history items in the binding `history` convention (docs/PROTOCOL.md, "Binding
/// conventions"; `AryaAdapters.HistoryItem`) from an export file or a tool result. Items are
/// decoded one by one, so a bad item is reported in `invalid` instead of failing the read.
public enum HistorySource {
    /// An export file: `{"v":1,"history":[…]}` (what `arya-fake-adapter --binding` serves) or
    /// one page, `{"items":[…]}`.
    public static func items(export data: Data) -> (items: [HistoryItem], invalid: [String]) {
        guard let value = try? CanonicalJSON.decode(JSONValue.self, from: data),
            let list = value["history"] ?? value["items"]
        else { return ([], ["not a history export: expected {\"history\": [...]}"]) }
        return decode(list)
    }

    /// One page of the `history` tool: `structuredContent`, or the first text content holding
    /// it as JSON. `next` is the cursor of the following page, absent on the last.
    public static func page(toolResult: JSONValue)
        -> (items: [HistoryItem], invalid: [String], next: String?)
    {
        var page = toolResult["structuredContent"]
        if page?["items"] == nil, let text = toolResult["content"]?[0]?["text"]?.stringValue {
            page = try? CanonicalJSON.decode(JSONValue.self, from: Data(text.utf8))
        }
        if page?["items"] == nil, toolResult["items"] != nil { page = toolResult }
        guard let page, let list = page["items"] else {
            return ([], ["the history tool returned no items"], nil)
        }
        let read = decode(list)
        return (read.items, read.invalid, page["next"]?.stringValue)
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
                let id = value["id"]?.stringValue ?? "item \(index + 1)"
                invalid.append("\(id): not a history item (needs id, at, input)")
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
    /// named `name`). `source` names where the items came from (`inbox.history`, a file name);
    /// `binding` names the binding the records belong to, so each item's `record` is served
    /// back as a recorded `<binding>.get` read.
    public func importHistory(
        _ items: [HistoryItem], invalid alreadyInvalid: [String] = [], into book: Casebook?,
        name: String, steward: StewardID, source: String, binding: String? = nil,
        limit: Int = 200, actor: RuntimeActor = .localUser
    ) async throws -> HistoryImportResult {
        let plan = try Self.plan(
            items, into: book, source: source, binding: binding, limit: limit,
            invalid: alreadyInvalid)
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
        _ items: [HistoryItem], into book: Casebook?, source: String, binding: String? = nil,
        limit: Int, invalid: [String]
    ) throws -> Plan {
        var plan = Plan(invalid: invalid)
        var ids = Set(book?.cases.map(\.id) ?? [])
        var inputs = Set(book?.cases.map { normalized($0.input.text) } ?? [])
        // Newest first; ties keep the binding's order.
        let ordered = items.enumerated().sorted { a, b in
            a.element.at != b.element.at ? a.element.at > b.element.at : a.offset < b.offset
        }.map(\.element)
        var fresh: [Case] = []
        for item in ordered {
            let id = item.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let input = item.input.trimmingCharacters(in: .whitespacesAndNewlines)
            let did = expected(item)
            if let reason = problem(id: id, input: input, did: did) {
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
            var reads: [RecordedToolResult] = []
            if let binding, let record = item.record {
                reads.append(
                    RecordedToolResult(
                        tool: "\(binding).get", input: ["id": .string(id)], output: record))
            }
            fresh.append(
                Case(
                    id: caseID, input: CaseInput(text: input),
                    context: CaseContext(toolResults: reads), expected: did,
                    source: provenance(item, id: id, source: source)))
        }
        let cap = max(0, limit)
        plan.cases = Array(fresh.prefix(cap))
        plan.overCap = max(0, fresh.count - cap)
        return plan
    }

    /// What the person did, as a case's expected result: their `choice` as the decision and
    /// each distinct action kind and target, in order (a rerouted record keeps both routes).
    static func expected(_ item: HistoryItem) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        if let choice = item.choice?.trimmingCharacters(in: .whitespaces), !choice.isEmpty {
            fields["decisions"] = [["choice": .string(choice)]]
        }
        var actions: [JSONValue] = []
        for action in item.actions {
            var entry: [String: JSONValue] = ["kind": .string(action.kind)]
            if let target = action.target { entry["target"] = .string(target) }
            if !actions.contains(.object(entry)) { actions.append(.object(entry)) }
        }
        if !actions.isEmpty { fields["actions"] = .array(actions) }
        return .object(fields)
    }

    /// `history inbox.history item MSG-004 by person:sam at 2026-09-03T11:00:00Z, reopened:
    /// Rerouted.`
    static func provenance(_ item: HistoryItem, id: String, source: String) -> String {
        var text = "history \(source) item \(id)"
        if let by = item.actions.compactMap(\.by).first { text += " by \(by)" }
        text += " at \(item.at)"
        if let outcome = item.outcome, outcome.status != "resolved" {
            text += ", \(outcome.status)"
            if let note = outcome.note, !note.isEmpty { text += ": \(note)" }
        }
        return text
    }

    static func problem(id: String, input: String, did: JSONValue) -> String? {
        if id.isEmpty { return "missing id" }
        if input.isEmpty { return "empty input" }
        if input.count > maxInput { return "input longer than \(maxInput) characters" }
        guard case .object(let fields) = did, !fields.isEmpty else {
            return "nobody acted on it"
        }
        return nil
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
