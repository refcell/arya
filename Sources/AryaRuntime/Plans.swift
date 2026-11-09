import AryaAdapters
import AryaCore
import AryaLedger

// A steward keeps a plan: the steps it means to take toward its outcome. A run may return
// `plan` in `run/result` (the whole plan, not a diff; PROTOCOL.md); when its ids, texts, or
// statuses differ from the current plan the runtime records `plan.updated`, and the next run's
// instructions show it, so the plan adapts over time.

/// Where one plan item stands.
public enum PlanStatus: String, Codable, Hashable, Sendable, CaseIterable {
    /// Not started.
    case pending
    /// Under way.
    case inProgress = "in_progress"
    /// Finished.
    case done
    /// Given up, with the reason in `rationale`.
    case skipped
    /// Waiting on something outside the steward.
    case blocked
}

/// One step of a steward's plan.
public struct PlanItem: Codable, Hashable, Sendable {
    /// Stable within the plan, chosen by the steward.
    public var id: String
    /// What the step is.
    public var text: String
    /// Where it stands.
    public var status: PlanStatus
    /// Why the step exists or why its status changed.
    public var rationale: String?

    /// Creates an item.
    public init(id: String, text: String, status: PlanStatus, rationale: String? = nil) {
        self.id = id
        self.text = text
        self.status = status
        self.rationale = rationale
    }

    enum CodingKeys: String, CodingKey { case id, text, status, rationale }
}

/// `plan.updated`: a steward's whole plan after a run changed it (actor: the steward, run: the
/// run that changed it).
public struct PlanUpdated: EventPayload {
    public static let type = EventType("plan.updated")
    /// The plan, in the steward's order.
    public var items: [PlanItem]
    /// Why it changed: the run's summary, when it has one.
    public var reason: String?

    /// Creates a payload.
    public init(items: [PlanItem], reason: String? = nil) {
        self.items = items
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey { case items, reason }
}

/// Event type names for plans.
public enum PlanEventType {
    /// `plan.updated`.
    public static let updated = PlanUpdated.type.rawValue
}

/// The current plan of each steward.
public struct PlanBook: Sendable {
    /// Plans by steward; a steward that never planned has none.
    public private(set) var plans: [StewardID: [PlanItem]] = [:]

    /// An empty book.
    public init() {}

    /// Builds the book from events in ledger order.
    public init(_ events: [RuntimeEvent]) throws {
        for event in events where event.type == PlanEventType.updated {
            guard let steward = event.draft.steward else { continue }
            plans[steward] = try Payload.decode(PlanUpdated.self, event.payload).items
        }
    }

    /// The plan a run result carries, or nil when it has none or it is malformed (an empty or
    /// repeated id, or empty text), which is ignored rather than failing the run.
    public static func plan(in result: RunResult) -> [PlanItem]? {
        let items = result.plan.map {
            PlanItem(
                id: $0.id, text: $0.text,
                status: PlanStatus(rawValue: $0.status.rawValue) ?? .pending,
                rationale: $0.rationale)
        }
        let ids = items.map(\.id)
        guard !items.isEmpty, Set(ids).count == ids.count,
            items.allSatisfy({ !$0.id.isEmpty && !$0.text.isEmpty })
        else { return nil }
        return items
    }

    /// True when two plans differ in their items' ids, texts, or statuses (a new rationale
    /// alone is not a change).
    public static func differs(_ a: [PlanItem], _ b: [PlanItem]?) -> Bool {
        guard let b else { return true }
        let key = { (items: [PlanItem]) in items.map { [$0.id, $0.text, $0.status.rawValue] } }
        return key(a) != key(b)
    }
}
