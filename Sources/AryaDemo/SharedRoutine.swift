import Arya
import AryaAdapters
import AryaCore
import Foundation

/// A routine two stewards share (connect lane, M3.6 #7): the triage steward proposes
/// `spot-duplicate-charges` from a weekly sweep, its gate promotes it, the refund steward
/// adopts the same version (`Workspace.adoptRoutine`, decision 0060), and both run it on
/// messages through `routine` actions a person approves. A message with no duplicate charge
/// makes the script exit 1, so the library's pass rate is real.
enum SharedRoutine {
    static let name = "spot-duplicate-charges"
    static let sweep = "Weekly sweep: find duplicate-charge messages"
    static let content = """
        #!/bin/sh
        # Print the lines that mention a duplicate or double charge; exit 1 when none do.
        grep -iE 'duplicate|double charge|charged (twice|two times)|repeated charge'

        """

    /// Version 2 (decision 0062): also catches "billed twice"; triage promotes it, and the
    /// refund steward, which follows triage, gets an upgrade it has not taken yet.
    static let sweepV2 = "Weekly sweep: duplicate charges worded as billed twice"
    static let contentV2 = """
        #!/bin/sh
        # Print the lines that mention a duplicate or double charge; exit 1 when none do.
        grep -iE 'duplicate|double charge|(charged|billed) (twice|two times)|repeated charge'

        """

    /// Messages each steward runs the routine on, by days ago; the third has no duplicate.
    static let runs: [(steward: String, days: Int, text: String)] = [
        ("st_triage", 11, "MSG-301: I was charged twice for one order"),
        ("st_triage", 9, "MSG-306: Double charge on my card this morning"),
        ("st_triage", 7, "MSG-311: Where is my invoice for October?"),
        ("st_triage", 5, "MSG-317: Repeated charge after I cancelled"),
        ("st_triage", 3, "MSG-322: Charged two times for the annual plan"),
        ("st_refunds", 8, "ORDER-1201: duplicate payment captured"),
        ("st_refunds", 6, "ORDER-1207: customer charged twice at checkout"),
        ("st_refunds", 4, "ORDER-1212: partial refund for a late delivery"),
        ("st_refunds", 2, "ORDER-1218: double charge on renewal"),
    ]

    /// The triage steward's adapters: charter v1's and v2's.
    static let triage = ["fake-triage", "fake-triage-v2"]

    static func input(_ text: String) -> String { "Check for a duplicate charge: \(text)" }

    /// Adds the sweep (proposes the routine) and each routine run to the example scripts.
    static func script(_ scripts: inout [String: FakeScript]) throws {
        let routine: JSONValue = .object([
            "name": .string(name), "language": "sh", "content": .string(content),
            "reason": "Duplicate charges arrive every week; a routine spots them in one pass.",
            "summary": "Spot duplicate-charge messages",
        ])
        let sweepResponse = try response(
            summary: "Swept the week's messages and proposed a routine for duplicate charges.",
            extra: ["routines": .array([routine])])
        for adapter in triage { scripts[adapter]?.responses[sweep] = sweepResponse }
        let v2: JSONValue = .object([
            "name": .string(name), "language": "sh", "content": .string(contentV2),
            "reason": "Two customers wrote \"billed twice\" and version 1 missed them.",
            "summary": "Also catch \"billed twice\"",
        ])
        let v2Response = try response(
            summary: "Found two duplicate charges version 1 missed and proposed version 2.",
            extra: ["routines": .array([v2])])
        for adapter in triage { scripts[adapter]?.responses[sweepV2] = v2Response }
        for run in runs {
            let adapters = run.steward == "st_triage" ? triage : ["fake-refunds"]
            let action: JSONValue = .object([
                "id": "a1", "kind": "routine", "target": .string(run.text),
                "params": .object(["name": .string(name), "input": .string(run.text)]),
                "rationale": "Check for a duplicate charge before routing.", "risk": "low",
            ])
            let reply = try response(
                summary: "Ran \(name) on \(run.text.prefix(while: { $0 != ":" })).",
                extra: ["actions": .array([action])])
            for adapter in adapters { scripts[adapter]?.responses[input(run.text)] = reply }
        }
    }

    private static func response(summary: String, extra: [String: JSONValue]) throws
        -> FakeScript.Response
    {
        var result: [String: JSONValue] = ["summary": .string(summary)]
        result.merge(extra) { $1 }
        let json: JSONValue = .object([
            "events": .array([]), "status": "completed", "result": .object(result),
        ])
        return try JSONDecoder().decode(
            FakeScript.Response.self, from: try JSONEncoder().encode(json))
    }

    /// Promotes triage's version 2 (gate, else an override); refunds is left on version 1.
    static func upgrade(_ workspace: Workspace) async throws {
        guard
            let row = try await workspace.routines(steward: "st_triage")
                .first(where: { $0.name == name }), row.latestVersion != row.liveVersion
        else { return }
        let gated = try await workspace.gateRoutine(
            steward: "st_triage", name: name, version: row.latestVersion)
        if !gated.promoted {
            try await workspace.overrideRoutine(
                steward: "st_triage", name: name, version: row.latestVersion,
                reason: "Checked on the two billed-twice messages.")
        }
    }

    /// Promotes the swept routine in triage through its gate (an override when the gate
    /// holds it) and has Priya use it in the refund steward.
    static func share(_ workspace: Workspace) async throws {
        guard
            let version = try await workspace.routines(steward: "st_triage")
                .first(where: { $0.name == name })?.latestVersion
        else { return }
        let gated = try await workspace.gateRoutine(
            steward: "st_triage", name: name, version: version)
        if !gated.promoted {
            try await workspace.overrideRoutine(
                steward: "st_triage", name: name, version: version,
                reason: "Spot-checked on this week's duplicate charges.")
        }
        let adopted = try await workspace.shareRoutine(
            name: name, version: version, from: "st_triage", into: "st_refunds",
            by: "person:priya")
        if !adopted.live {
            try await workspace.overrideRoutine(
                steward: "st_refunds", name: name, version: version,
                reason: "Refund duplicates are the same messages triage already checks.")
        }
    }
}
