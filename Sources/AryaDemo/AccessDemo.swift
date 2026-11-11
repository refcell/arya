import Arya
import AryaAdapters
import AryaCore
import Foundation

/// Access in the busy home (runtime, decisions 0064 and 0065): three teams and their grants
/// nine days ago, a few more grants by Jules (who approves everything) three days ago, and
/// hand-offs over the last week from people with no grant for what the steward then tries, so
/// Settings ▸ Access shows refusals from real runs. Support covers everyone whose messages
/// make a steward act elsewhere (Sam, Priya, Lee in triage and refunds), so the rest of the
/// demo runs as before.
enum AccessDemo {
    /// A hand-off whose run takes `kind` on `binding`, from a person with no grant for it.
    struct Attempt {
        let days: Int
        let hour: Double
        let steward: String
        let adapters: [String]
        let person: String
        let text: String
        let kind: String
        let binding: String
        let target: String
    }

    /// Each from a person bound to the steward (only they may message it) who has no grant
    /// for the action: Kai before Jules grants him Alerts, Lena on product adoption (her grant
    /// covers churn watch), Omar who only approves vendor spend, and Ren, who may draft release
    /// notes but not publish them.
    static let attempts: [Attempt] = [
        Attempt(
            days: 6, hour: 10.25, steward: "st_oncall_digest", adapters: ["demo-oncall_digest"],
            person: "person:kai", text: "Post tonight's maintenance window to the on-call channel.",
            kind: "post", binding: "alerts", target: "shift:SHIFT-MAINT"),
        Attempt(
            days: 5, hour: 14.5, steward: "st_product_adoption",
            adapters: ["demo-product_adoption"], person: "person:lena",
            text: "Open a task for the Acme account owner about the seat drop.",
            kind: "task", binding: "crm", target: "acct:ACME"),
        Attempt(
            days: 4, hour: 11.75, steward: "st_vendor_spend_review",
            adapters: ["demo-vendor_spend_review"], person: "person:omar",
            text: "Flag the analytics renewal for review.",
            kind: "flag", binding: "spend", target: "spend:ANALYTICS"),
        Attempt(
            days: 2, hour: 9.5, steward: "st_release_notes", adapters: ["demo-release_notes"],
            person: "person:ren", text: "Publish the mobile release notes now.",
            kind: "publish", binding: "repo", target: "rel:REL-MOBILE"),
        Attempt(
            days: 1, hour: 13.25, steward: "st_product_adoption",
            adapters: ["demo-product_adoption"], person: "person:lena",
            text: "Note that Globex asked for a usage review.",
            kind: "note", binding: "crm", target: "acct:GLOBEX"),
    ]

    static func input(_ attempt: Attempt) -> String {
        "\(attempt.person) hands this to you: \(attempt.text)"
    }

    /// Adds each attempt's reply (one action on the steward's binding) to its scripts.
    static func script(_ scripts: inout [String: FakeScript]) throws {
        for attempt in attempts {
            let action: JSONValue = .object([
                "id": "a1", "kind": .string(attempt.kind), "binding": .string(attempt.binding),
                "target": .string(attempt.target),
                "params": .object(["text": .string(attempt.text)]), "risk": "low",
                "rationale": "Asked for directly in a hand-off.",
            ])
            let json: JSONValue = .object([
                "events": .array([]), "status": "completed",
                "result": .object([
                    "summary": .string("Took the hand-off: \(attempt.text)"),
                    "actions": .array([action]),
                ]),
            ])
            let reply = try JSONDecoder().decode(
                FakeScript.Response.self, from: try JSONEncoder().encode(json))
            for adapter in attempt.adapters {
                scripts[adapter]?.responses[input(attempt)] = reply
            }
        }
    }

    /// Phase 0: the teams and their grants, by you. Phase 1: Jules adds grants.
    static func setup(_ workspace: Workspace, phase: Int) async throws {
        if phase == 0 {
            for (id, name, members) in [
                ("team:support", "Support", ["person:sam", "person:priya", "person:lee"]),
                ("team:finance", "Finance", ["person:omar", "person:priya"]),
                ("team:sales", "Sales", ["person:maya", "person:jules"]),
            ] {
                _ = try await workspace.setTeam(id, name: name, members: members)
            }
            for (level, resource, subject) in [
                ("use", "steward:st_triage", "team:support"),
                ("use", "steward:st_refunds", "team:support"),
                ("approve", "steward:st_triage", "team:support"),
                ("use", "steward:st_invoice_chasing", "team:finance"),
                ("use", "connection:ledger", "team:finance"),
                ("approve", "steward:st_vendor_spend_review", "person:omar"),
                ("use", "steward:st_lead_follow_up", "team:sales"),
                ("use", "steward:st_churn_watch", "person:lena"),
                ("approve", "*", "person:jules"),
            ] {
                _ = try await workspace.grantAccess(level, on: resource, to: subject)
            }
        } else {
            for (level, resource, subject) in [
                ("use", "tool:repo.draft", "person:ren"),
                ("use", "connection:alerts", "person:kai"),
                ("view", "steward:st_customer_commitments", "team:sales"),
            ] {
                _ = try await workspace.grantAccess(
                    level, on: resource, to: subject, as: "person:jules")
            }
        }
    }
}
