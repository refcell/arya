import AryaCore
import AryaRuntime
import Foundation

// Every steward's outcome against its target, grouped by department, and a catalog of example
// stewards to start from.

/// One steward on the portfolio screen.
public struct PortfolioItem: Sendable, Hashable, Codable {
    /// The fleet fields: state, metric against target, status, approvals, last run, next wake.
    public var fleet: FleetItem
    /// The outcome it owns, in words.
    public var outcome: String
    /// `up` or `down`: which way the metric should move.
    public var direction: String
    /// The metric per window, oldest first, for a sparkline; nil where no reading exists.
    public var trend: [Double?]
    public var owner: String?
    public var department: String?
}

/// The portfolio: stewards grouped by department, with counts by status.
public struct Portfolio: Sendable, Hashable, Codable {
    public struct Group: Sendable, Hashable, Codable {
        /// The department, or `Unassigned`.
        public var department: String
        /// Ordered as `fleet()`: needs a person first, then off track, then by name.
        public var items: [PortfolioItem]
    }

    public var groups: [Group]
    public var onTrack: Int
    public var offTrack: Int
    /// Stewards with no target or no data yet.
    public var unmeasured: Int
    /// Stewards with something waiting on a person.
    public var needsYou: Int
}

/// An example steward to start from.
public struct StewardTemplate: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    /// One line on what it owns.
    public var summary: String
    public var department: String
    /// The fields `createSteward(_:)` takes; ids and the adapter can be changed before creating.
    public var draft: StewardDraft
}

extension Workspace {
    /// Every active or paused steward's outcome against its target, by department
    /// (alphabetical, `Unassigned` last).
    public func portfolio(windows: Int = 14, timeZone: TimeZone = .current) async throws
        -> Portfolio
    {
        let fleet = try await self.fleet(timeZone: timeZone)
        let records = Dictionary(
            try await lifecycle.book().all.map { ($0.id.rawValue, $0) },
            uniquingKeysWith: { first, _ in first })
        var items: [PortfolioItem] = []
        for entry in fleet {
            let outcome = try await self.outcome(steward: entry.steward, windows: windows)
            let charter = records[entry.steward]?.charter
            items.append(
                PortfolioItem(
                    fleet: entry, outcome: outcome.outcome, direction: outcome.direction,
                    trend: outcome.trend.map(\.value), owner: charter?.owner,
                    department: charter?.department))
        }
        let unassigned = "Unassigned"
        let grouped = Dictionary(grouping: items) { $0.department ?? unassigned }
        let names = grouped.keys.sorted {
            if ($0 == unassigned) != ($1 == unassigned) { return $1 == unassigned }
            return $0.localizedStandardCompare($1) == .orderedAscending
        }
        return Portfolio(
            groups: names.map { Portfolio.Group(department: $0, items: grouped[$0] ?? []) },
            onTrack: fleet.filter { $0.status == "on_track" }.count,
            offTrack: fleet.filter { $0.status == "off_track" }.count,
            unmeasured: fleet.filter { $0.status == "no_target" || $0.status == "no_data" }.count,
            needsYou: fleet.filter { $0.needsYou > 0 }.count)
    }

    /// The example stewards to start from.
    public nonisolated func templates() -> [StewardTemplate] { StewardTemplates.all }

    /// Creates a steward from a template; `id`, `name`, `adapter`, and `owner` replace the
    /// template's when given.
    public func createFromTemplate(
        _ template: String, id: String? = nil, name: String? = nil, adapter: String? = nil,
        owner: String? = nil
    ) async throws -> StewardSummary {
        guard let found = StewardTemplates.all.first(where: { $0.id == template }) else {
            throw WorkspaceError.notFound(template)
        }
        var draft = found.draft
        if let name, !name.isEmpty {
            draft.name = name
            draft.id = id ?? "st_" + StewardDraft.slug(name)
        }
        if let id { draft.id = id }
        if let adapter, !adapter.isEmpty { draft.adapter = adapter }
        if let owner, !owner.isEmpty { draft.owner = owner }
        return try await createSteward(draft)
    }
}

/// The template catalog. `etc/examples/templates/<id>.json` holds each as a charter document
/// (a test keeps them in sync).
enum StewardTemplates {
    typealias Binding = StewardDraft.Binding
    typealias Rule = StewardDraft.Rule
    typealias Trigger = StewardDraft.Trigger

    static let hourly = [Trigger(kind: "interval", everySeconds: 3600), Trigger(kind: "manual")]
    static let daily = [Trigger(kind: "interval", everySeconds: 86_400), Trigger(kind: "manual")]

    static let all: [StewardTemplate] = [
        StewardTemplate(
            id: "support_triage", name: "Support triage",
            summary:
                "Labels and routes every new support message, and drafts replies for sign-off.",
            department: "Support",
            draft: StewardDraft(
                id: "st_support_triage", name: "Support triage",
                outcome: "Every new support message is labeled and routed to the right queue "
                    + "within one hour.",
                metric: "routed_within_1h", unit: "ratio", target: 0.95,
                guardrails: [
                    "Never delete a message.", "Ask before replying to a customer.",
                    "Route anything about security to the security queue.",
                ],
                rules: [
                    Rule(
                        action: "label", decision: "auto",
                        note: "Labels are safe to change, so the steward applies them."),
                    Rule(
                        action: "route", decision: "auto",
                        note: "Routing only moves a message between queues."),
                    Rule(
                        action: "reply", decision: "ask",
                        note: "Replies to customers need sign-off."),
                ],
                bindings: [
                    Binding(
                        id: "inbox", kind: "mcp", command: "inbox-mcp", read: ["search", "get"],
                        actions: ["label", "route", "reply"])
                ],
                triggers: [
                    Trigger(kind: "interval", everySeconds: 900), Trigger(kind: "manual"),
                ],
                adapter: "default", department: "Support")),
        StewardTemplate(
            id: "lead_follow_up", name: "Lead follow-up",
            summary: "Makes sure every inbound lead gets a first reply and an owner within a day.",
            department: "Sales",
            draft: StewardDraft(
                id: "st_lead_follow_up", name: "Lead follow-up",
                outcome: "Every new inbound lead gets an owner and a first reply within one "
                    + "business day.",
                metric: "first_reply_within_1d", unit: "ratio", target: 0.9,
                guardrails: [
                    "Never promise pricing or discounts.",
                    "Ask before emailing a lead for the first time.",
                ],
                rules: [
                    Rule(
                        action: "note", decision: "auto",
                        note: "Notes on a lead are internal, so they are added on their own."),
                    Rule(
                        action: "assign", decision: "ask",
                        note: "A person confirms who owns each lead."),
                    Rule(
                        action: "send_email", decision: "ask",
                        note: "Emails to prospects need sign-off."),
                ],
                bindings: [
                    Binding(
                        id: "crm", kind: "mcp", command: "crm-mcp", read: ["search", "get"],
                        actions: ["note", "assign", "send_email"])
                ],
                triggers: hourly, adapter: "default", level: "suggest", department: "Sales")),
        StewardTemplate(
            id: "vendor_spend_review", name: "Vendor spend review",
            summary: "Reviews large vendor renewals before they renew and flags savings.",
            department: "Finance",
            draft: StewardDraft(
                id: "st_vendor_spend_review", name: "Vendor spend review",
                outcome: "Every vendor renewal above the review threshold is reviewed two "
                    + "weeks before it renews.",
                metric: "renewals_reviewed_on_time", unit: "ratio", target: 0.95,
                guardrails: [
                    "Never cancel or sign a contract.",
                    "Flag a renewal instead of contacting the vendor.",
                ],
                rules: [
                    Rule(
                        action: "flag", decision: "auto",
                        note: "Flags only mark a renewal for review."),
                    Rule(
                        action: "comment", decision: "ask",
                        note: "Comments are visible to the budget owner, so they need sign-off."
                    ),
                ],
                bindings: [
                    Binding(
                        id: "spend", kind: "mcp", command: "spend-mcp",
                        read: ["contracts", "invoices"], actions: ["flag", "comment"])
                ],
                triggers: daily, adapter: "default", level: "suggest", department: "Finance")),
        StewardTemplate(
            id: "product_adoption", name: "Product adoption",
            summary: "Spots accounts that stop using a key feature and sets up a follow-up.",
            department: "Customer success",
            draft: StewardDraft(
                id: "st_product_adoption", name: "Product adoption",
                outcome: "Accounts that stop using a key feature get a follow-up within one week.",
                metric: "lapsed_accounts_followed_up", unit: "ratio", target: 0.8,
                guardrails: [
                    "Never contact a customer directly.",
                    "Create tasks for account owners instead.",
                ],
                rules: [
                    Rule(
                        action: "task", decision: "auto",
                        note: "Tasks go to the account owner, who decides what to do."),
                    Rule(
                        action: "note", decision: "auto", note: "Account notes are internal."),
                ],
                bindings: [
                    Binding(
                        id: "usage", kind: "mcp", command: "usage-mcp", read: ["accounts", "usage"]
                    ),
                    Binding(
                        id: "crm", kind: "mcp", command: "crm-mcp", read: ["get"],
                        actions: ["task", "note"]),
                ],
                triggers: daily, adapter: "default", level: "act_low",
                department: "Customer success")),
        StewardTemplate(
            id: "customer_commitments", name: "Customer commitments",
            summary: "Tracks every promise made to a customer and chases it before it is late.",
            department: "Account management",
            draft: StewardDraft(
                id: "st_customer_commitments", name: "Customer commitments",
                outcome: "Every commitment made to a customer is tracked and met by its due date.",
                metric: "commitments_met_on_time", unit: "ratio", target: 0.95,
                guardrails: [
                    "Never change a due date without the owner.",
                    "Remind the owner before telling the customer anything.",
                ],
                rules: [
                    Rule(
                        action: "create", decision: "auto",
                        note: "Tracking a commitment changes nothing for the customer."),
                    Rule(
                        action: "remind", decision: "auto",
                        note: "Reminders go to the internal owner."),
                    Rule(
                        action: "update", decision: "ask",
                        note: "Changing a commitment needs its owner."),
                ],
                bindings: [
                    Binding(
                        id: "tracker", kind: "mcp", command: "tracker-mcp",
                        read: ["search", "get"], actions: ["create", "update", "remind"])
                ],
                triggers: hourly, adapter: "default", level: "suggest",
                department: "Account management")),
    ]
}
