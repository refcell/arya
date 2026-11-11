import AryaDesign
import Foundation

/// How a steward is doing against its target, as the Outcome tab's status pill shows it.
enum OutcomeStatus: String, Hashable, Sendable {
    /// `paused` replaces the target status while the steward takes no live triggers.
    /// `recovering`: on target today after missing it on recent days (`OutcomeState.missed`).
    case onTrack, atRisk, offTrack, noTarget, noData, paused, recovering

    var word: String {
        switch self {
        case .paused: "paused"
        case .recovering: "recovering"
        case .onTrack: "on track"
        case .atRisk: "at risk"
        case .offTrack: "off track"
        case .noTarget: "no target"
        case .noData: "no data"
        }
    }

    /// Shortfall from target, relative to the target's size, that still counts as at risk.
    static let atRiskShortfall = 0.05

    /// The status of `value` against `target` in `direction`.
    static func of(
        value: Double?, target: Double?, direction: MetricDefinition.Direction
    ) -> OutcomeStatus {
        guard let target else { return .noTarget }
        guard let value else { return .noData }
        let shortfall = direction == .up ? target - value : value - target
        if shortfall <= 0 { return .onTrack }
        let scale = max(abs(target), 1e-9)
        return shortfall / scale <= atRiskShortfall ? .atRisk : .offTrack
    }
}

/// Whether the steward may take live triggers, and if not, why not.
enum OutcomeReadiness: Hashable, Sendable {
    case ready(charterVersion: Int)
    case notReady(reason: String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// "ready (v1)" or "not ready: rehearsal passed 1 of 3".
    var text: String {
        switch self {
        case .ready(let version): "ready (v\(version))"
        case .notReady(let reason): "not ready: \(reason)"
        }
    }

    static func build(events: [FeatureEvent], steward: String) -> OutcomeReadiness {
        guard let live = LiveCharter.find(events: events, steward: steward)?.version else {
            return .notReady(reason: "no charter")
        }
        let mine = events.filter { $0.steward == steward || $0.steward == nil }
        let ready = mine.contains {
            $0.type == "steward.ready" && $0.steward == steward
                && Int($0.payload["charterVersion"]?.number ?? -1) == live
        }
        if ready { return .ready(charterVersion: live) }
        let started = mine.last {
            $0.type == "rehearsal.started"
                && Int($0.payload["charterVersion"]?.number ?? -1) == live
                && $0.payload["proposal"] == nil
        }
        guard let started, let id = started.payload["rehearsal"]?.string else {
            return .notReady(reason: "never rehearsed on past work")
        }
        let finished = mine.last {
            $0.type == "rehearsal.finished" && $0.payload["rehearsal"]?.string == id
        }
        guard let finished else { return .notReady(reason: "rehearsal in progress") }
        let cases = Int(started.payload["cases"]?.number ?? 0)
        let passed = Int(finished.payload["passed"]?.number ?? 0)
        return .notReady(reason: "rehearsal passed \(passed) of \(cases); review and mark ready")
    }
}

/// How much the steward may do on its own, read from the charter's approval policy.
struct OutcomeAutonomy: Hashable, Sendable {
    enum Level: String, Hashable, Sendable {
        /// Everything waits for a person unless denied.
        case supervised
        /// Some action kinds run on their own; the rest ask.
        case assisted
        /// Actions run on their own unless a rule says otherwise.
        case autonomous
        /// Nothing runs; every action is denied by default.
        case locked
    }

    var level: Level
    var auto: [String]
    var ask: [String]
    var deny: [String]

    static func build(charter: FeatureJSON?) -> OutcomeAutonomy {
        let policy = charter?["policy"]
        let fallback = policy?["default"]?.string ?? "ask"
        var lists: [String: [String]] = [:]
        for rule in policy?["rules"]?.array ?? [] {
            guard let action = rule["action"]?.string, let decision = rule["decision"]?.string
            else { continue }
            // A kind ruled twice (per binding) is listed once.
            if lists[decision]?.contains(action) != true {
                lists[decision, default: []].append(action)
            }
        }
        let auto = lists["auto"] ?? []
        let level: Level =
            switch fallback {
            case "auto": .autonomous
            case "deny": auto.isEmpty ? .locked : .assisted
            default: auto.isEmpty ? .supervised : .assisted
            }
        return OutcomeAutonomy(
            level: level, auto: auto, ask: lists["ask"] ?? [], deny: lists["deny"] ?? [])
    }

    /// "assisted · auto label · never close".
    var text: String {
        var parts = [level.rawValue]
        if !auto.isEmpty { parts.append("auto " + auto.joined(separator: ", ")) }
        if !deny.isEmpty { parts.append("never " + deny.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

/// When the steward wakes next.
enum OutcomeWake: Hashable, Sendable {
    case at(Date)
    case paused
    /// Only manual or message triggers: it runs when someone asks.
    case onDemand

    static func build(
        events: [FeatureEvent], steward: String, charter: FeatureJSON?, now: Date
    ) -> OutcomeWake {
        let mine = events.filter { $0.steward == steward }
        let pause = mine.last { ["steward.paused", "steward.resumed"].contains($0.type) }
        if pause?.type == "steward.paused" { return .paused }
        let intervals = (charter?["triggers"]?.array ?? []).compactMap { trigger -> Double? in
            guard trigger["kind"]?.string == "interval" else { return nil }
            return trigger["everySeconds"]?.number
        }
        guard let every = intervals.min(), every > 0 else { return .onDemand }
        let anchor =
            mine.last {
                $0.type == "run.started" && $0.payload["trigger"]?.string == "interval"
            }?.at ?? mine.first { $0.type == "steward.created" }?.at ?? now
        var next = anchor.addingTimeInterval(every)
        if next < now {
            let missed = (now.timeIntervalSince(next) / every).rounded(.up)
            next = next.addingTimeInterval(missed * every)
        }
        return .at(next)
    }

    /// The last `limit` live top-level runs that ended (not rehearsals or child runs), oldest
    /// first: true when the run finished, false when it failed. Mirrors the runtime's
    /// `ScheduleStatus.recent` until the facade exposes it.
    static func triggers(events: [FeatureEvent], steward: String, limit: Int = 5) -> [Bool] {
        var live: Set<String> = []
        var ended: [Bool] = []
        for event in events where event.steward == steward {
            guard let run = event.run else { continue }
            switch event.type {
            case "run.started":
                if !OutcomeRuns.isRehearsal(event.payload), event.payload["parent"] == nil {
                    live.insert(run)
                }
            case "run.finished" where live.contains(run): ended.append(true)
            case "run.failed" where live.contains(run): ended.append(false)
            default: continue
            }
        }
        return Array(ended.suffix(limit))
    }

    /// The schedule line's lead: "Next run 14:00", "Next run Nov 10", "Paused", or
    /// "Runs on demand".
    /// With the scheduler stopped a due time is not a promise: "Scheduler stopped · next due
    /// 09:00".
    func schedule(now: Date, serving: Bool? = nil, timeZone: TimeZone = .current) -> String {
        switch self {
        case .paused: return "Paused"
        case .onDemand: return "Runs on demand"
        case .at(let date):
            let time = AryaTime.upcoming(date, now: now, timeZone: timeZone)
            return serving == false ? "Scheduler stopped · next due \(time)" : "Next run \(time)"
        }
    }

    func text(now: Date) -> String {
        switch self {
        case .paused: return "paused"
        case .onDemand: return "on demand"
        case .at(let date):
            let seconds = Int(date.timeIntervalSince(now))
            if seconds < 60 { return "in under a minute" }
            if seconds < 3600 { return "in \(seconds / 60)m" }
            if seconds < 86_400 { return "in \(seconds / 3600)h" }
            return "in \(seconds / 86_400)d"
        }
    }
}

/// The headline of the Outcome tab: what the steward owns and how it is doing.
struct OutcomeState: Hashable, Sendable {
    var outcome: String
    var metric: MetricDefinition?
    var points: [MetricPoint]
    var status: OutcomeStatus
    /// The charter's own success definition, or one written from the metric and target.
    var success: String
    var readiness: OutcomeReadiness
    var autonomy: OutcomeAutonomy
    var wake: OutcomeWake
    /// Whether triggers fire at all (`FeatureServe.serving`); nil when unknown.
    var serving: Bool? = nil
    /// Measured days in the recent window that missed the target, and the days measured; the
    /// status and FINDINGS both use this window.
    var missed = 0
    var window = 0
    /// The workspace's own missed line and status line, when read (`applying(_:)`).
    var windowMissed: String?? = nil
    /// The primary metric's `line` from `metricStatuses`, shown beside the status pill.
    var reason: String? = nil
    /// The last five live triggered runs that ended, oldest first: true when it finished.
    var triggers: [Bool] = []
    /// Values for the sparkline: daily means, or each reading while there is under two days.
    var trend: [Double]

    var latest: Double? { points.last?.value }

    /// Measured days the status and FINDINGS look back over.
    static let recentDays = 5

    /// The reason beside the status pill: the missed line when any day missed (why it is
    /// recovering or at risk), else the clause after the metric in the workspace's status
    /// line ("on track, improving."); nil while paused or unread.
    var why: String? {
        guard status != .paused else { return nil }
        if let missedText { return missedText }
        guard let reason else { return nil }
        guard let colon = reason.range(of: ": ", options: .backwards) else { return reason }
        return String(reason[colon.upperBound...])
    }

    /// The workspace's `missed its target on 4 of the last 7 days` when read, else "missed 3
    /// of 5 days" from the ledger when any recent day missed.
    var missedText: String? {
        if let windowMissed { return windowMissed }
        return missed > 0 ? "missed \(missed) of \(window) \(window == 1 ? "day" : "days")" : nil
    }

    /// The workspace's reads replace the ledger's estimates (one source per fact): the status
    /// comes from the primary metric's `metricStatuses` status (on target, an inclusive
    /// bound, is on track), its line is the reason, and the missed text is the evaluation
    /// window's.
    func applying(_ reads: OutcomeReads?) -> OutcomeState {
        guard let reads else { return self }
        var state = self
        if let missedText = reads.missedText { state.windowMissed = missedText }
        guard let primary = reads.primary else { return state }
        state.reason = primary.line
        guard status != .paused else { return state }
        switch primary.status {
        case "on_track": state.status = state.missedText == nil ? .onTrack : .recovering
        case "off_track":
            state.status = [.atRisk, .offTrack].contains(status) ? status : .atRisk
        case "no_target": state.status = .noTarget
        case "no_data": state.status = .noData
        default: break
        }
        return state
    }

    static func build(
        events: [FeatureEvent], steward: String, now: Date, serve: FeatureServe? = nil
    ) -> OutcomeState {
        let charter = LiveCharter.find(events: events, steward: steward)?.charter
        let series = MetricSeries.build(events: events, steward: steward)
        let metric = series?.definition
        let points = series?.points ?? []
        let ledgerWake = OutcomeWake.build(
            events: events, steward: steward, charter: charter, now: now)
        let wake = serve?.wake(ledgerWake, steward: steward) ?? ledgerWake
        let measured =
            metric.map {
                OutcomeStatus.of(
                    value: points.last?.value, target: $0.target, direction: $0.direction)
            } ?? .noTarget
        var missed = 0
        let recent = points.suffix(Self.recentDays)
        if let metric, let target = metric.target {
            missed =
                recent.filter {
                    metric.direction == .up ? $0.value < target : $0.value > target
                }.count
        }
        var status: OutcomeStatus = wake == .paused ? .paused : measured
        if status == .onTrack, missed > 0 { status = .recovering }
        var trend = points.map(\.value)
        if trend.count < 2, let name = metric?.name {
            trend = events.compactMap { event in
                guard event.steward == steward, event.type == "metric.recorded",
                    event.payload["metric"]?.string == name
                else { return nil }
                return event.payload["value"]?.number
            }
        }
        return OutcomeState(
            outcome: charter?["outcome"]?.string ?? "",
            metric: metric, points: points, status: status,
            success: charter?["success"]?.string ?? OutcomeText.success(metric),
            readiness: OutcomeReadiness.build(events: events, steward: steward),
            autonomy: OutcomeAutonomy.build(charter: charter),
            wake: wake, serving: serve?.serving, missed: missed, window: recent.count,
            triggers: OutcomeWake.triggers(events: events, steward: steward), trend: trend)
    }
}

/// The Overview's recap rule; times themselves go through `AryaTime.label`.
enum OutcomeTime {
    /// The recap appears only after this long away.
    static let recapGapSeconds: TimeInterval = 15 * 60
}

/// Text for the Outcome tab, kept apart from layout so it can be tested.
enum OutcomeText {
    /// "triaged_within_1h at 0.95 or more", the success definition a metric implies.
    static func success(_ metric: MetricDefinition?) -> String {
        guard let metric else { return "No success metric in the charter." }
        guard let target = metric.target else {
            return "\(MetricText.name(metric.name)) keeps improving."
        }
        let side = metric.direction == .up ? "or more" : "or less"
        return "\(MetricText.name(metric.name)) at \(MetricText.value(target)) \(side)."
    }

    /// "Review 1 approval", the primary action when something waits on the person.
    static func review(_ count: Int) -> String {
        "Review \(count) approval" + (count == 1 ? "" : "s")
    }

    /// "triaged_within_1h is 0.93 against a target of 0.95, at risk."
    static func spoken(_ state: OutcomeState) -> String {
        guard let metric = state.metric else { return "No outcome metric." }
        var text =
            "\(MetricText.name(metric.name)) is "
            + (state.latest.map(MetricText.value) ?? "not measured")
        if let target = metric.target { text += " against a target of \(MetricText.value(target))" }
        text += ", \(state.status.word)"
        if let missed = state.missedText { text += ", \(missed)" }
        return text + "."
    }

    /// "↑ higher is better" or "↓ lower is better".
    static func direction(_ direction: MetricDefinition.Direction) -> String {
        direction == .up ? "↑ higher is better" : "↓ lower is better"
    }

    /// "+0.03 over 5d" from the first and last points, or nil with fewer than two.
    static func change(_ points: [MetricPoint]) -> String? {
        guard let first = points.first, let last = points.last, points.count >= 2 else {
            return nil
        }
        let delta = last.value - first.value
        let days = Int((last.day.timeIntervalSince(first.day) / 86_400).rounded())
        return "\(OutcomeDashboardText.credit(delta)) over \(days)d"
    }
}
