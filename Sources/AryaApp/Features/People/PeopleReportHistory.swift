import Foundation

/// A steward's past reports (`report.sent`, oldest first in the ledger, newest first here) and
/// how each reached its recipients: the inbox gets it at once; a person reached through a relay
/// gets it from the report run's `send` action, under the charter's policy (decision 0050).
struct PeopleReportHistory: Hashable, Sendable {
    enum Status: String, Hashable, Sendable {
        case inbox, sent, drafted, waiting, denied, failed, unknown

        var label: String {
            switch self {
            case .inbox: "in inbox"
            case .sent: "sent"
            case .drafted: "drafted, not sent"
            case .waiting: "waiting for approval"
            case .denied: "denied"
            case .failed: "failed"
            case .unknown: "no record"
            }
        }
    }

    struct Recipient: Hashable, Sendable, Identifiable {
        var id: String
        var name: String
        var via: String?
        var status: Status
    }

    struct Sent: Hashable, Sendable, Identifiable {
        var id: String
        var at: Date
        var cadence: String
        /// The report's first line, "Weekly report: Support inbox triage, Nov 2 to Nov 9."
        var subject: String
        var text: String
        /// Who sent it: arya on schedule, or a person with Send now.
        var by: FeatureActor
        var run: String?
        var recipients: [Recipient]
    }

    var sent: [Sent]

    init(events: [FeatureEvent], steward: String) {
        // Report run → person binding → the send's status.
        var sends: [String: [String: Status]] = [:]
        var actionPerson: [String: String] = [:]
        for event in events where event.steward == steward {
            guard let run = event.run else { continue }
            switch event.type {
            case "action.proposed":
                guard let action = event.payload["action"],
                    let person = action["binding"]?.string, person.hasPrefix("person:"),
                    let id = action["id"]?.string
                else { continue }
                actionPerson["\(run)/\(id)"] = person
                let disposition = event.payload["disposition"]?.string
                sends[run, default: [:]][person] =
                    disposition == "deny" ? .denied : disposition == "ask" ? .waiting : .unknown
            case "action.executed", "action.failed":
                guard let id = event.payload["action"]?.string,
                    let person = actionPerson["\(run)/\(id)"]
                else { continue }
                sends[run, default: [:]][person] =
                    event.type == "action.failed"
                    ? .failed : event.payload["dryRun"]?.bool == true ? .drafted : .sent
            default: continue
            }
        }
        sent = events.filter { $0.steward == steward && $0.type == "report.sent" }.reversed()
            .map { event in
                let run = event.payload["run"]?.string
                let text = event.payload["text"]?.string ?? ""
                let recipients = (event.payload["to"]?.array ?? []).compactMap {
                    to -> Recipient? in
                    guard let person = to["person"]?.string else { return nil }
                    let via = to["via"]?.string
                    let status: Status =
                        via == nil ? .inbox : run.flatMap { sends[$0]?[person] } ?? .unknown
                    return Recipient(
                        id: person,
                        name: to["name"]?.string ?? PeopleDirectory.displayName(person),
                        via: via, status: status)
                }
                return Sent(
                    id: event.id, at: event.at,
                    cadence: event.payload["cadence"]?.string ?? "",
                    subject: text.split(separator: "\n").first.map(String.init) ?? "Report",
                    text: text, by: event.actor, run: run, recipients: recipients)
            }
    }
}
