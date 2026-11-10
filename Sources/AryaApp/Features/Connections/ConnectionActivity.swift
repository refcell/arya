import Foundation

/// What stewards did through each connection, read from the ledger: tool calls (an adapter
/// `tool_call` names `binding.tool`, for example `inbox.search`) and actions (`action.proposed`
/// on the binding, settled by `action.executed` or `action.failed`).
struct ConnectionActivity: Hashable, Sendable {
    struct Call: Hashable, Sendable, Identifiable {
        enum Kind: String, Hashable, Sendable { case read, did, failed, proposed }

        /// The event id.
        var id: String
        var at: Date
        var steward: String?
        var run: String?
        var kind: Kind
        /// "search", or "label inbox:MSG-201".
        var what: String
    }

    /// By connection id, oldest first.
    private(set) var calls: [String: [Call]] = [:]

    init(events: [FeatureEvent]) {
        // Run/action id → index of its proposed call, so a settle updates it in place.
        var proposed: [String: (binding: String, index: Int)] = [:]
        for event in events {
            switch event.type {
            case "run.adapter.event":
                guard let inner = event.payload["message"]?["params"]?["event"],
                    inner["kind"]?.string == "tool_call", let tool = inner["tool"]?.string,
                    let dot = tool.firstIndex(of: ".")
                else { continue }
                let binding = String(tool[..<dot])
                calls[binding, default: []].append(
                    Call(
                        id: event.id, at: event.at, steward: event.steward, run: event.run,
                        kind: .read, what: String(tool[tool.index(after: dot)...])))
            case "action.proposed":
                guard let action = event.payload["action"],
                    let binding = action["binding"]?.string, let kind = action["kind"]?.string
                else { continue }
                // "reply Sam", "follow-up inbox:MSG-140": machine words as people read them.
                let target = (action["target"]?.string).map {
                    $0.hasPrefix("person:") ? PeopleDirectory.displayName($0) : $0
                }
                let word = ActionWords.kind(kind)
                calls[binding, default: []].append(
                    Call(
                        id: event.id, at: event.at, steward: event.steward, run: event.run,
                        kind: .proposed, what: target.map { "\(word) \($0)" } ?? word))
                if let run = event.run, let id = action["id"]?.string {
                    proposed["\(run)/\(id)"] = (binding, calls[binding, default: []].count - 1)
                }
            case "action.executed", "action.failed":
                guard let run = event.run, let id = event.payload["action"]?.string,
                    let found = proposed["\(run)/\(id)"]
                else { continue }
                calls[found.binding]?[found.index].kind =
                    event.type == "action.executed" ? .did : .failed
                calls[found.binding]?[found.index].at = event.at
            default: continue
            }
        }
    }

    /// The newest calls through `connection`, newest first.
    func recent(_ connection: String, limit: Int = 6) -> [Call] {
        Array((calls[connection] ?? []).suffix(limit).reversed())
    }

    /// Calls per day through `connection` for the `days` days ending today, oldest first.
    func daily(_ connection: String, now: Date, days: Int = 7) -> [Double] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var counts = [Double](repeating: 0, count: days)
        for call in calls[connection] ?? [] {
            let day =
                calendar.dateComponents(
                    [.day], from: calendar.startOfDay(for: call.at), to: today
                ).day ?? days
            if day >= 0, day < days { counts[days - 1 - day] += 1 }
        }
        return counts
    }

    /// Calls through `connection` in the last `days` days.
    func count(_ connection: String, now: Date, days: Int = 7) -> Int {
        Int(daily(connection, now: now, days: days).reduce(0, +))
    }
}
