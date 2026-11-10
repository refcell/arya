import AryaCore
import AryaLedger
import AryaRuntime
import Foundation

// Periodic reports (connect lane): a charter's `report` block names who gets a digest and how
// often. The digest is built from the outcome trend and the recap since the last report, and
// each send is recorded as `report.sent`, addressed to each person through their own binding
// (the local inbox, or their address on a relay), so the People thread shows it as delivered.

/// One person a report goes to, through their person binding.
public struct ReportRecipient: Sendable, Hashable, Codable {
    /// The person binding id, for example `person:sam`.
    public var person: String
    public var name: String?
    /// `inbox`, or their address on the relay.
    public var channel: String
    /// The relay connection, nil for the local inbox.
    public var via: String?
}

/// A report as it would go out now.
public struct ReportDigest: Sendable, Hashable, Codable {
    public var steward: String
    /// `daily` or `weekly`.
    public var cadence: String
    /// The period it covers.
    public var from: Date
    public var through: Date
    /// The ledger `seq` of the previous report (0 for none) and the newest one it covers.
    public var sinceSeq: Int
    public var throughSeq: Int
    /// The digest, one sentence or item per line.
    public var lines: [String]
    public var to: [ReportRecipient]
    /// False when the charter has no `report` block (the digest is a preview to every person).
    public var configured: Bool

    public var text: String { lines.joined(separator: "\n") }
}

/// `report.sent`: a report recorded as delivered to its recipients (actor: who sent it).
struct ReportSent: Codable {
    static let type = "report.sent"
    var cadence: String
    var since: Int
    var through: Int
    var days: Int
    var text: String
    var to: [ReportRecipient]
    /// The report run that sent it to people reached through a relay (runtime decision 0050).
    var run: String?
}

extension Workspace {
    /// The report `steward` would send now: the charter's `report` block, or a weekly preview
    /// to every person when it has none.
    public func reportDigest(steward: String) async throws -> ReportDigest {
        let record = try await existing(steward)
        let charter = record.charter
        let config =
            charter.report
            ?? ReportConfig(
                to: charter.bindings.filter { $0.kind == .person }.map(\.id), cadence: .weekly)
        let events = try facadeState().events
        let last = events.last {
            $0.steward == record.id && $0.type.rawValue == ReportSent.type
        }
        let through = now()
        let from = through.addingTimeInterval(-Double(config.days) * 86_400)
        let sinceSeq = last.map { Int($0.seq) } ?? 0
        let recap = try await recap(steward: steward, since: sinceSeq)
        let outcome = try await outcome(steward: steward, windows: config.days + 1)
        let to = config.to.compactMap { id -> ReportRecipient? in
            guard let binding = charter.binding(id), binding.kind == .person else { return nil }
            return ReportRecipient(
                person: id, name: binding.name, channel: binding.channel ?? "inbox",
                via: binding.via)
        }
        // People read names, not binding ids: "Reply to Sam", not "Reply person:sam".
        let names = Dictionary(
            charter.bindings.compactMap { binding in binding.name.map { (binding.id, $0) } },
            uniquingKeysWith: { first, _ in first })
        let lines = ReportText.lines(
            name: charter.name, cadence: config.cadence, from: from, through: through,
            outcome: outcome, recap: recap, since: from
        ).map { line in
            names.reduce(line) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
        }
        return ReportDigest(
            steward: record.id.rawValue, cadence: config.cadence.rawValue, from: from,
            through: through, sinceSeq: sinceSeq, throughSeq: recap.through,
            lines: lines,
            to: to, configured: charter.report != nil)
    }

    /// Sends `steward`'s report now: records `report.sent` to the people its `report` block
    /// names, through their bindings. Rejected when the charter has no `report` block or names
    /// no one.
    @discardableResult
    public func sendReport(steward: String, by person: String = "local") async throws
        -> ReportDigest
    {
        let id = try await existing(steward).id
        let digest = try await reportDigest(steward: steward)
        guard digest.configured else {
            throw WorkspaceError.rejected("\(steward) has no report in its charter")
        }
        guard !digest.to.isEmpty else {
            throw WorkspaceError.rejected("\(steward)'s report names no person binding")
        }
        // People reached through a relay get it from a report run: one `send` action each,
        // under the charter's policy and approvals (runtime decision 0050).
        let relayed = digest.to.filter { $0.via != nil }.map(\.person)
        let delivery = try await engine.report(
            digest.text, subject: digest.lines.first ?? "Report", to: relayed, steward: id,
            actor: person == "arya" ? .system : .person(person))
        let payload = ReportSent(
            cadence: digest.cadence, since: digest.sinceSeq, through: digest.throughSeq,
            days: digest.cadence == "daily" ? 1 : 7, text: digest.text, to: digest.to,
            run: delivery?.run.rawValue)
        _ = try await sink.append(
            RuntimeEventDraft(
                type: ReportSent.type, steward: id,
                actor: person == "arya" ? .system : .person(person),
                payload: try CanonicalJSON.decode(
                    JSONValue.self, from: try CanonicalJSON.encode(payload))))
        return digest
    }

    /// Active stewards whose report is due: its latest slot (the charter's UTC hour, on its
    /// weekday for weekly reports) has passed and no report went out since.
    public func dueReports() async throws -> [String] {
        let now = now()
        let events = try facadeState().events
        return try await stewardBook().all.compactMap { record in
            guard record.status == .active, let config = record.charter.report else { return nil }
            let slot = ReportSchedule.latestSlot(config, before: now)
            let sent = events.last {
                $0.steward == record.id && $0.type.rawValue == ReportSent.type
            }
            if let sent, sent.at.date >= slot { return nil }
            return record.id.rawValue
        }
    }

    /// Sends every due report (`arya serve`'s tick calls it) and returns the stewards sent.
    @discardableResult
    public func sendDueReports() async throws -> [String] {
        var sent: [String] = []
        for steward in try await dueReports() {
            try await sendReport(steward: steward, by: "arya")
            sent.append(steward)
        }
        return sent
    }
}

enum ReportSchedule {
    /// The newest moment at or before `now` a report with `config` goes out.
    static func latestSlot(_ config: ReportConfig, before now: Date) -> Date {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let start = calendar.startOfDay(for: now)
        var slot = start.addingTimeInterval(Double(config.at) * 3600)
        if slot > now { slot = slot.addingTimeInterval(-86_400) }
        guard config.cadence == .weekly else { return slot }
        // ISO weekday: Calendar's 1 is Sunday, so Monday (2) maps to 1.
        for _ in 0..<7 {
            let weekday = (calendar.component(.weekday, from: slot) + 5) % 7 + 1
            if weekday == config.day { return slot }
            slot = slot.addingTimeInterval(-86_400)
        }
        return slot
    }
}

enum ReportText {
    static func lines(
        name: String, cadence: ReportConfig.Cadence, from: Date, through: Date,
        outcome: OutcomeSummary, recap: Recap, since: Date
    ) -> [String] {
        var out: [String] = []
        let period = cadence == .weekly ? "Weekly" : "Daily"
        out.append("\(period) report: \(name), \(day(from)) to \(day(through)).")
        out.append(metric(outcome, cadence: cadence))
        let activity = recap.activity.filter { $0.at >= since }
        let actions = activity.filter { $0.kind == "action" }.count
        let decisions = activity.filter { $0.kind == "decision" }.count
        let runs = Set(activity.compactMap(\.run)).count
        let failed = recap.unresolved.filter { $0.at >= since }.count
        var did = "Did: \(count(runs, "run")), \(count(decisions, "decision")), "
        did += "\(count(actions, "action"))"
        did += failed > 0 ? "; \(failed) failed." : "."
        out.append(did)
        for item in activity.filter({ $0.kind == "action" }).suffix(3).reversed() {
            out.append("- \(item.text)")
        }
        if !recap.pendingApprovals.isEmpty {
            out.append("Waiting on people: \(count(recap.pendingApprovals.count, "approval")).")
        }
        return out
    }

    static func metric(_ outcome: OutcomeSummary, cadence: ReportConfig.Cadence) -> String {
        guard let current = outcome.current else {
            return "\(outcome.metric): no value recorded yet."
        }
        var line = "\(outcome.metric) \(value(current, outcome.unit))"
        if let target = outcome.target {
            let status = outcome.status == .onTrack ? "on track" : "behind"
            line += " against a target of \(value(target, outcome.unit)) (\(status))"
        }
        if let first = outcome.trend.first(where: { $0.value != nil })?.value,
            outcome.trend.count > 1, first != current
        {
            let ago = cadence == .weekly ? "a week ago" : "a day ago"
            let way = current > first ? "up" : "down"
            line += ", \(way) from \(value(first, outcome.unit)) \(ago)"
        }
        return line + "."
    }

    static func value(_ number: Double, _ unit: String) -> String {
        let text =
            number.rounded() == number && abs(number) < 1e9
            ? String(Int(number)) : String(format: "%.2f", number)
        // Dimensionless units read better as the bare number: "0.96", not "0.96 ratio".
        if unit.isEmpty || ["ratio", "fraction", "score"].contains(unit) { return text }
        return unit == "%" ? text + "%" : "\(text) \(unit)"
    }

    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    static func day(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "MMM d"
        return format.string(from: date)
    }
}
