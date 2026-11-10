import Arya
import Foundation

/// Pure conversions from facade read models to CLI view models.
enum Mapping {
    static func steward(_ steward: StewardSummary, pendingApprovals: Int, lastRun: String?)
        -> StewardRow
    {
        let state: StewardState =
            switch steward.status {
            case .retired: .retired
            case .paused: .paused
            case .active: steward.ready ? .ready : .draft
            }
        return StewardRow(
            id: steward.id, name: steward.name, state: state,
            charterVersion: steward.charterVersion, pendingApprovals: pendingApprovals,
            lastRun: lastRun)
    }

    static func detail(_ row: StewardRow, outcome: String, charter: CharterDigest?)
        -> StewardDetail
    {
        StewardDetail(
            summary: row, outcome: outcome, metric: charter?.metric,
            guardrails: charter?.guardrails ?? [], bindings: charter?.bindings ?? [],
            triggers: charter?.triggers ?? [], adapter: charter?.adapter,
            effort: charter?.effort)
    }

    static func approval(_ approval: ApprovalSummary) -> ApprovalRow {
        let state: ApprovalState =
            switch approval.status {
            case .pending: .pending
            case .granted: .granted
            case .denied: .denied
            case .expired: .expired
            }
        return ApprovalRow(
            id: approval.id, steward: approval.steward, run: approval.run,
            action: approval.actionKind ?? approval.kind.rawValue, target: approval.target ?? "-",
            rationale: approval.text, state: state, requestedAt: timestamp(approval.requestedAt),
            heldBy: approval.policyRule, heldBecause: approval.policyText)
    }

    static func event(_ entry: LedgerEntry) -> EventSummary {
        EventSummary(
            seq: entry.seq, at: timestamp(entry.at), type: entry.type,
            actor: "\(entry.actorKind):\(entry.actorID)", steward: entry.steward, run: entry.run)
    }

    static func verify(_ check: LedgerCheck) -> VerifyReport {
        let firstBreak = check.firstBadSeq.map {
            VerifyReport.Break(seq: $0, reason: check.detail ?? "chain broken")
        }
        return VerifyReport(isValid: check.ok, events: check.events, firstBreak: firstBreak)
    }

    /// A run report from the run summary, its ledger entries, and its approvals.
    static func report(_ run: RunSummary, entries: [LedgerEntry], approvals: [ApprovalSummary])
        -> RunReport
    {
        let status: String =
            switch run.status {
            case .running: "running"
            case .finished: run.endStatus ?? "completed"
            case .failed: "failed"
            }
        let digest = RunDigest(entries: entries, approvals: approvals)
        let summary = run.summary ?? run.failureReason.map { "failed: \($0)" } ?? ""
        return RunReport(
            run: run.id, steward: run.steward, status: status, summary: summary,
            decisions: digest.decisions, actions: digest.actions)
    }

    /// A run report from the facade's run detail.
    static func report(_ detail: RunDetail, crew members: [RunSummary]) -> RunReport {
        var report = report(detail)
        report.parent = detail.run.parent
        report.crew = members.filter { $0.trigger != "join" }.map(\.id)
        report.join = members.first { $0.trigger == "join" }?.id
        return report
    }

    static func report(_ detail: RunDetail) -> RunReport {
        let base = report(detail.run, entries: [], approvals: [])
        let actions = detail.actions.map { action in
            let disposition: ActionDisposition =
                switch action.disposition {
                case .proposed: .proposed
                case .held: .held
                case .executed: .executed
                case .failed: .failed
                case .rejected: .rejected
                }
            return ActionOutcome(
                id: action.id, kind: action.kind, target: action.target ?? "-",
                disposition: disposition, approval: disposition == .held ? action.approval : nil)
        }
        return RunReport(
            run: base.run, steward: base.steward, status: base.status, summary: base.summary,
            decisions: detail.decisions.map(\.choice), actions: actions,
            parent: detail.run.parent)
    }

    static func casebook(_ summary: CasebookSummary) -> CasebookRow {
        CasebookRow(
            name: summary.name, steward: summary.steward, version: summary.version,
            cases: summary.cases)
    }

    static func rehearsal(_ summary: RehearsalSummary) -> RehearsalReport {
        RehearsalReport(
            rehearsal: summary.id, steward: summary.steward, casebook: summary.casebook,
            passed: summary.passed, total: summary.total, score: summary.meanScore,
            failed: summary.failed,
            cases: summary.cases.map {
                RehearsedCase(id: $0.id, passed: $0.passed, score: $0.score, leak: $0.leak)
            })
    }

    /// One series per metric: the charter's metric first, then any others by name. A point is
    /// a window's mean; windows without a value for the metric are left out.
    static func series(_ summary: MetricSeriesSummary) -> [MetricSeries] {
        let names = Set(summary.windows.flatMap(\.means.keys)).subtracting([summary.metric])
        return ([summary.metric] + names.sorted()).map { name in
            let points = summary.windows.compactMap { window in
                window.means[name].map { MetricPoint(at: timestamp(window.start), value: $0) }
            }
            let isCharter = name == summary.metric
            return MetricSeries(
                metric: name, unit: isCharter ? summary.unit : nil,
                target: isCharter ? summary.target : nil, points: points)
        }
    }

    /// A charter proposal; an open proposal is still rehearsing.
    static func proposal(_ summary: ProposalSummary) -> ProposalRow {
        ProposalRow(
            id: summary.id, steward: summary.steward, kind: "charter",
            state: ProposalState(rawValue: summary.status) ?? .rehearsing,
            baseline: summary.verdict?.baselineMean, candidate: summary.verdict?.candidateMean,
            regressions: summary.verdict?.regressions ?? [])
    }

    static func replay(_ summary: ReplaySummary) -> ReplayReport {
        ReplayReport(
            run: summary.run, events: summary.events,
            divergences: summary.divergences.map {
                Divergence(
                    seq: $0.seq ?? $0.index, type: $0.type, field: $0.field,
                    recorded: $0.recorded, replayed: $0.replayed)
            })
    }

    static func fleet(_ item: FleetItem) -> FleetRow {
        FleetRow(
            steward: item.steward, name: item.name, state: item.state, ready: item.ready,
            metric: item.metric, unit: item.unit, current: item.current, target: item.target,
            status: item.status, pendingApprovals: item.pendingApprovals,
            needsYou: item.needsYou,
            lastRun: item.lastRun.map {
                FleetRow.LastRun(
                    id: $0.id, title: $0.title, status: $0.status, at: timestamp($0.time.date))
            },
            nextWake: item.nextWake.map { timestamp($0.date) })
    }

    /// RFC 3339 UTC with milliseconds, the ledger's time format.
    static func timestamp(_ date: Date) -> String {
        let millis = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
        let seconds = millis >= 0 ? millis / 1000 : (millis - 999) / 1000
        let fraction = millis - seconds * 1000
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: Date(timeIntervalSince1970: TimeInterval(seconds)))
        func pad(_ value: Int?, _ width: Int) -> String {
            let text = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        return "\(pad(parts.year, 4))-\(pad(parts.month, 2))-\(pad(parts.day, 2))T"
            + "\(pad(parts.hour, 2)):\(pad(parts.minute, 2)):\(pad(parts.second, 2))."
            + "\(pad(Int(fraction), 3))Z"
    }
}

/// The charter fields `arya steward create` prints, read leniently from charter JSON.
struct CharterDigest: Sendable, Equatable {
    var metric: String?
    var guardrails: [String] = []
    var bindings: [String] = []
    var triggers: [String] = []
    var adapter: String?
    var effort: String?

    init?(json data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let metric = object["metric"] as? [String: Any], let name = metric["name"] as? String {
            var details = [metric["unit"], metric["direction"]].compactMap { $0 as? String }
            if let target = metric["target"] as? NSNumber { details.append("target \(target)") }
            self.metric = details.isEmpty ? name : "\(name) (\(details.joined(separator: ", ")))"
        }
        guardrails = object["guardrails"] as? [String] ?? []
        let bindingObjects = object["bindings"] as? [[String: Any]] ?? []
        bindings = bindingObjects.compactMap { $0["id"] as? String }
        let triggerObjects = object["triggers"] as? [[String: Any]] ?? []
        triggers = triggerObjects.compactMap(Self.trigger)
        adapter = object["adapter"] as? String
        effort = object["effort"] as? String ?? "medium"
    }

    private static func trigger(_ object: [String: Any]) -> String? {
        guard let kind = object["kind"] as? String else { return nil }
        if kind == "interval", let every = object["everySeconds"] as? Int {
            return "every \(every)s"
        }
        return kind
    }
}

/// Decisions and action outcomes of one run, read leniently from its ledger entries. Payloads
/// are matched on the field names in ARCHITECTURE.md and PROTOCOL.md; an action may be inline
/// or nested under `action`, and outcome events may name it by id or embed it.
struct RunDigest: Sendable, Equatable {
    var decisions: [String] = []
    var actions: [ActionOutcome] = []

    init(entries: [LedgerEntry], approvals: [ApprovalSummary]) {
        var order: [String] = []
        var proposed: [String: (kind: String, target: String)] = [:]
        var outcome: [String: (ActionDisposition, String?)] = [:]
        for entry in entries.sorted(by: { $0.seq < $1.seq }) {
            let payload = Self.object(entry.payload)
            switch entry.type {
            case "run.decision":
                let decision = payload["decision"] as? [String: Any] ?? payload
                if let choice = decision["choice"] as? String { decisions.append(choice) }
            case "action.proposed":
                let action = payload["action"] as? [String: Any] ?? payload
                guard let id = action["id"] as? String else { continue }
                order.append(id)
                proposed[id] = (
                    action["kind"] as? String ?? "action", action["target"] as? String ?? "-"
                )
            case "action.executed": Self.actionID(payload).map { outcome[$0] = (.executed, nil) }
            case "action.failed": Self.actionID(payload).map { outcome[$0] = (.failed, nil) }
            case "action.rejected": Self.actionID(payload).map { outcome[$0] = (.rejected, nil) }
            case "approval.requested":
                if let id = Self.actionID(payload), outcome[id] == nil {
                    let approval = payload["approval"] as? String ?? payload["id"] as? String
                    outcome[id] = (.held, approval)
                }
            default: continue
            }
        }
        actions = order.compactMap { id in
            guard let action = proposed[id] else { return nil }
            var (disposition, approval) = outcome[id] ?? (.proposed, nil)
            if disposition == .proposed,
                let match = approvals.first(where: {
                    $0.actionKind == action.kind && $0.target == action.target
                })
            {
                (disposition, approval) = (.held, match.id)
            }
            return ActionOutcome(
                id: id, kind: action.kind, target: action.target, disposition: disposition,
                approval: disposition == .held ? approval : nil)
        }
    }

    private static func object(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
    }

    private static func actionID(_ payload: [String: Any]) -> String? {
        if let id = payload["action"] as? String { return id }
        return (payload["action"] as? [String: Any])?["id"] as? String
    }
}
