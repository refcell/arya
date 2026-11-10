import AryaCore
import Foundation

/// The `history` binding tool convention: a binding lists past records together with what a
/// person did with each, so arya can learn from decisions made before it arrived (eval builds
/// casebooks from it). See docs/PROTOCOL.md, "Binding conventions".
public enum BindingHistory {
    /// The tool name a binding serves the convention under.
    public static let tool = "history"
    /// Items per page when `limit` is absent.
    public static let defaultLimit = 50
    /// The largest page a caller may ask for.
    public static let maxLimit = 500

    /// One page of `items`, oldest first: those with `since <= at < until`, starting after
    /// `cursor`. The cursor is the offset into the filtered list, as a string; bindings may use
    /// any opaque cursor.
    public static func page(_ items: [HistoryItem], _ params: HistoryListParams)
        -> HistoryListResult
    {
        let ordered = items.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
        let selected = ordered.filter { item in
            (params.since.map { item.at >= $0 } ?? true)
                && (params.until.map { item.at < $0 } ?? true)
        }
        let start = min(max(params.cursor.flatMap(Int.init) ?? 0, 0), selected.count)
        let limit = min(max(params.limit ?? defaultLimit, 1), maxLimit)
        let end = min(start + limit, selected.count)
        return HistoryListResult(
            items: Array(selected[start..<end]), next: end < selected.count ? String(end) : nil)
    }
}

/// Arguments of the `history` tool. Times are RFC 3339 in UTC (`Z`), so they compare as text.
public struct HistoryListParams: Sendable, Hashable, Codable {
    /// Only records at or after this time.
    public var since: String?
    /// Only records before this time.
    public var until: String?
    /// The `next` value of the previous page.
    public var cursor: String?
    /// Items per page, 1 to ``BindingHistory/maxLimit``; default ``BindingHistory/defaultLimit``.
    public var limit: Int?

    public init(
        since: String? = nil, until: String? = nil, cursor: String? = nil, limit: Int? = nil
    ) {
        self.since = since
        self.until = until
        self.cursor = cursor
        self.limit = limit
    }

    enum CodingKeys: String, CodingKey {
        case since, until, cursor, limit
    }
}

/// One page of the `history` tool. `next` is absent on the last page.
public struct HistoryListResult: Sendable, Hashable, Codable {
    public var items: [HistoryItem]
    public var next: String?

    public init(items: [HistoryItem], next: String? = nil) {
        self.items = items
        self.next = next
    }

    enum CodingKeys: String, CodingKey {
        case items, next
    }
}

/// A past record and what a person did with it.
public struct HistoryItem: Sendable, Hashable, Codable {
    /// The record's id in the binding (what its `get` tool takes).
    public var id: String
    /// When the record arrived (RFC 3339, UTC).
    public var at: String
    /// The run input arya would have received for it, such as `New message MSG-1: Subject`.
    public var input: String
    /// The record as the binding's `get` tool returns it, when the binding has one.
    public var record: JSONValue?
    /// What people did with the record, in order. Empty when nobody acted on it.
    public var actions: [HistoryAction]
    /// The person's decision in one word, such as a category or queue.
    public var choice: String?
    /// How it turned out.
    public var outcome: HistoryOutcome?

    public init(
        id: String, at: String, input: String, record: JSONValue? = nil,
        actions: [HistoryAction] = [], choice: String? = nil, outcome: HistoryOutcome? = nil
    ) {
        self.id = id
        self.at = at
        self.input = input
        self.record = record
        self.actions = actions
        self.choice = choice
        self.outcome = outcome
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        at = try c.decode(String.self, forKey: .at)
        input = try c.decode(String.self, forKey: .input)
        record = try c.decodeIfPresent(JSONValue.self, forKey: .record)
        actions = try c.decodeIfPresent([HistoryAction].self, forKey: .actions) ?? []
        choice = try c.decodeIfPresent(String.self, forKey: .choice)
        outcome = try c.decodeIfPresent(HistoryOutcome.self, forKey: .outcome)
    }

    enum CodingKeys: String, CodingKey {
        case id, at, input, record, actions, choice, outcome
    }
}

/// One thing a person did with a record, in the same terms as a proposed action.
public struct HistoryAction: Sendable, Hashable, Codable {
    /// The action kind, such as `label`, `route`, or `reply`.
    public var kind: String
    /// What it acted on, such as `inbox:MSG-1`.
    public var target: String?
    public var params: JSONValue?
    /// Who did it, as a binding contact id such as `person:sam`.
    public var by: String?
    /// When (RFC 3339, UTC).
    public var at: String?

    public init(
        kind: String, target: String? = nil, params: JSONValue? = nil, by: String? = nil,
        at: String? = nil
    ) {
        self.kind = kind
        self.target = target
        self.params = params
        self.by = by
        self.at = at
    }

    enum CodingKeys: String, CodingKey {
        case kind, target, params, by, at
    }
}

/// How a record turned out. `status` is `resolved`, `reopened` (the first handling was not
/// enough), or `open`; a binding may use other words, which readers keep as text.
public struct HistoryOutcome: Sendable, Hashable, Codable {
    public var status: String
    public var at: String?
    public var note: String?

    public init(status: String, at: String? = nil, note: String? = nil) {
        self.status = status
        self.at = at
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case status, at, note
    }
}
