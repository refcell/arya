import Foundation

/// How a steward's metric moves over its history, as a fraction `f` from 0 (first run) to 1
/// (now).
enum Curve {
    /// Straight from `from` to `to`.
    case linear(from: Double, to: Double)
    /// Falls from `from` to `dip` by the middle, then climbs to `to`.
    case recovering(from: Double, dip: Double, to: Double)

    func value(at f: Double) -> Double {
        switch self {
        case .linear(let from, let to): return from + (to - from) * f
        case .recovering(let from, let dip, let to):
            return f < 0.5 ? from + (dip - from) * f * 2 : dip + (to - dip) * (f - 0.5) * 2
        }
    }
}

/// One person bound to a steward: they message it and it reports to them.
struct Person {
    let id: String
    let name: String
    let role: String
}

/// A generated steward: a template charter with overrides, and what its history looks like.
struct StewardSpec {
    /// The template file in `etc/examples/templates` the charter starts from.
    let template: String
    let id: String
    let name: String
    let department: String
    var outcome: String? = nil
    /// Replaces the template's metric: name, target, unit, direction.
    var metric: (name: String, target: Double, unit: String, direction: String)? = nil
    /// Replaces the template's bindings with one MCP binding.
    var binding: (id: String, command: String, read: [String], actions: [String])? = nil
    /// Replaces the template's policy rules.
    var rules: [(action: String, decision: String, note: String)]? = nil
    var guardrails: [String]? = nil
    let people: [Person]
    /// Run inputs read `<prefix>-<number>: <one of details>`.
    let prefix: String
    let details: [String]
    /// The binding tool a run reads first.
    let tool: String
    /// Decisions a run makes, in rotation.
    let choices: [String]
    /// The action every run takes on its own (low risk).
    let autoKind: String
    /// An action held for a person every `askEvery` runs (medium risk), if any.
    var askKind: String? = nil
    var askEvery: Int = 4
    let curve: Curve
    /// Days of history before today.
    let days: Int
    /// Runs per day, inclusive.
    let runsPerDay: ClosedRange<Int>
    /// Its script answers the run `just snapshot` keeps in progress (`GeneratedSteward.live`).
    var live = false
    /// Messages people sent it: days ago, person, intent, text.
    var messages: [(days: Int, person: String, intent: String, text: String)] = []
}

/// The generated part of the demo fleet: ten departments' worth of work next to the three
/// example stewards (triage, refund follow-up, weekly digest).
enum DemoStewards {
    static let all: [StewardSpec] = [
        StewardSpec(
            template: "lead_follow_up", id: "st_lead_follow_up", name: "Lead follow-up",
            department: "Sales",
            people: [Person(id: "person:maya", name: "Maya", role: "sales lead")],
            prefix: "LEAD",
            details: [
                "Trial signup from a 40-seat team", "Demo request, wants pricing",
                "Inbound from the webinar", "Referral from an existing customer",
                "Pricing page visit, asked for a call",
            ],
            tool: "crm.search", choices: ["qualified", "nurture", "qualified", "disqualified"],
            autoKind: "note", askKind: "send_email", askEvery: 3,
            curve: .linear(from: 0.78, to: 0.93), days: 49, runsPerDay: 1...3, live: true,
            messages: [
                (5, "person:maya", "ask", "Which leads from the webinar still have no reply?"),
                (2, "person:maya", "handoff", "Follow up with the 40-seat trial team today."),
            ]),
        StewardSpec(
            template: "vendor_spend_review", id: "st_vendor_spend_review",
            name: "Vendor spend review", department: "Finance",
            people: [Person(id: "person:omar", name: "Omar", role: "finance lead")],
            prefix: "VND",
            details: [
                "Cloud storage renewal in 14 days", "Design tool seats up 30%",
                "Analytics contract auto-renews", "Support desk add-on unused for 60 days",
            ],
            tool: "spend.contracts", choices: ["review", "renew", "review", "cancel-candidate"],
            autoKind: "flag", askKind: "comment", askEvery: 3,
            curve: .linear(from: 0.88, to: 0.79), days: 42, runsPerDay: 1...3,
            messages: [
                (3, "person:omar", "ask", "Why did the analytics renewal slip past review?")
            ]),
        StewardSpec(
            template: "product_adoption", id: "st_product_adoption", name: "Product adoption",
            department: "Customer success",
            people: [Person(id: "person:lena", name: "Lena", role: "success manager")],
            prefix: "ACCT",
            details: [
                "No logins for 21 days", "Usage down 40% month over month",
                "Admin left the company", "Never finished setup",
            ],
            tool: "usage.accounts", choices: ["follow-up", "watch", "follow-up"],
            autoKind: "task",
            curve: .recovering(from: 0.74, dip: 0.52, to: 0.77), days: 56, runsPerDay: 1...2,
            messages: [
                (1, "person:lena", "correct", "Accounts in onboarding are not lapsed yet.")
            ]),
        StewardSpec(
            template: "customer_commitments", id: "st_customer_commitments",
            name: "Customer commitments", department: "Account management",
            people: [Person(id: "person:jules", name: "Jules", role: "account manager")],
            prefix: "CMT",
            details: [
                "Promised an export fix by Friday", "Quarterly review deck due",
                "Custom report promised to the CFO", "SSO setup call promised",
            ],
            tool: "tracker.search", choices: ["on-track", "at-risk", "on-track", "on-track"],
            autoKind: "remind", askKind: "update", askEvery: 5,
            curve: .linear(from: 0.93, to: 0.97), days: 42, runsPerDay: 1...2),
        StewardSpec(
            template: "customer_commitments", id: "st_release_notes", name: "Release notes",
            department: "Engineering",
            outcome: "Every release ships with notes customers can read, within a day.",
            metric: ("notes_within_1d", 0.9, "ratio", "up"),
            binding: ("repo", "repo-mcp", ["changes", "issues"], ["draft", "publish"]),
            rules: [
                ("draft", "auto", "Drafts stay private until published."),
                ("publish", "ask", "Published notes reach every customer."),
            ],
            guardrails: ["Never mention unreleased features.", "Link every fix to its issue."],
            people: [Person(id: "person:ren", name: "Ren", role: "release manager")],
            prefix: "REL",
            details: ["Patch release", "Minor release", "Hotfix for exports", "Mobile release"],
            tool: "repo.changes", choices: ["drafted", "drafted", "needs-review"],
            autoKind: "draft", askKind: "publish", askEvery: 2,
            curve: .linear(from: 0.84, to: 0.94), days: 35, runsPerDay: 1...1,
            messages: [(4, "person:ren", "ask", "Did the mobile release notes go out?")]),
        StewardSpec(
            template: "customer_commitments", id: "st_oncall_digest", name: "On-call digest",
            department: "Engineering",
            outcome: "The on-call team starts each shift with a digest of open alerts.",
            metric: ("digests_before_shift", 0.95, "ratio", "up"),
            binding: ("alerts", "alerts-mcp", ["open", "history"], ["post"]),
            rules: [("post", "auto", "The digest goes to the on-call channel only.")],
            guardrails: ["Never acknowledge or silence an alert."],
            people: [Person(id: "person:kai", name: "Kai", role: "on-call lead")],
            prefix: "SHIFT",
            details: ["Morning shift", "Evening shift", "Weekend shift"],
            tool: "alerts.open", choices: ["posted"], autoKind: "post",
            curve: .linear(from: 0.96, to: 0.99), days: 28, runsPerDay: 1...2),
        StewardSpec(
            template: "vendor_spend_review", id: "st_invoice_chasing", name: "Invoice chasing",
            department: "Finance",
            outcome: "Overdue invoices are chased within two days of their due date.",
            metric: ("chased_within_2d", 0.85, "ratio", "up"),
            binding: ("ledger", "ledger-mcp", ["invoices", "payments"], ["note", "remind"]),
            rules: [
                ("note", "auto", "Notes stay inside finance."),
                ("remind", "ask", "Reminders reach the customer."),
            ],
            guardrails: ["Never threaten collections.", "Never change an invoice amount."],
            people: [Person(id: "person:omar", name: "Omar", role: "finance lead")],
            prefix: "INV",
            details: [
                "Invoice 7 days overdue", "Partial payment received", "Disputed line item",
                "Invoice 30 days overdue",
            ],
            tool: "ledger.invoices", choices: ["remind", "wait", "remind", "escalate"],
            autoKind: "note", askKind: "remind", askEvery: 2,
            curve: .linear(from: 0.8, to: 0.66), days: 42, runsPerDay: 1...2),
        StewardSpec(
            template: "product_adoption", id: "st_churn_watch", name: "Churn watch",
            department: "Customer success",
            outcome: "Accounts showing churn signals get a plan within a week.",
            metric: ("at_risk_with_plan", 0.75, "ratio", "up"),
            people: [Person(id: "person:lena", name: "Lena", role: "success manager")],
            prefix: "RISK",
            details: [
                "Seats dropped by half", "Support tickets doubled", "Champion went quiet",
                "Renewal in 30 days, low usage",
            ],
            tool: "usage.usage", choices: ["plan", "watch", "plan"], autoKind: "note",
            curve: .recovering(from: 0.7, dip: 0.48, to: 0.72), days: 49, runsPerDay: 1...2),
    ]
}
