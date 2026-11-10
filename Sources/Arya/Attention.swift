import AryaCore
import AryaEval
import AryaLedger
import AryaRuntime
import Foundation

// What needs a person now, time text from the workspace's clock, and the ledger inspector.

/// A time as views show it, computed from the workspace's clock (`Ambient`), not the
/// device's, so seeded or replayed homes read correctly.
public struct TimeText: Sendable, Hashable, Codable {
    public var date: Date
    /// Locale-free local time, for example `2026-11-02 14:05`.
    public var absolute: String
    /// For example `just now`, `5 min ago`, `3 h ago`, `yesterday`, `4 days ago`, `3 weeks ago`,
    /// or the absolute date after about two months.
    public var relative: String

    public init(_ date: Date, now: Date, timeZone: TimeZone = .current) {
        self.date = date
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let pad = { (value: Int?) in value.map { $0 < 10 ? "0\($0)" : "\($0)" } ?? "00" }
        let day = "\(parts.year ?? 0)-\(pad(parts.month))-\(pad(parts.day))"
        absolute = "\(day) \(pad(parts.hour)):\(pad(parts.minute))"
        let seconds = Int(now.timeIntervalSince(date))
        let days =
            calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
            ).day ?? 0
        relative =
            switch seconds {
            case ..<(-60): "at \(absolute)"
            case ..<60: "just now"
            case ..<3600: "\(seconds / 60) min ago"
            case ..<(12 * 3600) where days == 0: "\(seconds / 3600) h ago"
            default:
                switch days {
                case ...0: "\(seconds / 3600) h ago"
                case 1: "yesterday"
                case ..<14: "\(days) days ago"
                case ..<60: "\(days / 7) weeks ago"
                default: day
                }
            }
    }
}

/// One thing waiting on a person.
public struct NeedsYouItem: Sendable, Hashable, Codable {
    /// What kind of attention it needs.
    public enum Kind: String, Sendable, Hashable, Codable {
        /// A held action or a question.
        case approval
        /// The steward's newest run failed.
        case failedRun = "failed_run"
        /// The newest rehearsal is older than the live charter or the newest casebook.
        case staleRehearsal = "stale_rehearsal"
    }

    /// What a view opens for this item.
    public struct Link: Sendable, Hashable, Codable {
        /// `approval`, `run`, or `rehearsals`.
        public var kind: String
        public var id: String
    }

    public var kind: Kind
    public var steward: String
    /// One line, for example "Reply to inbox:MSG-9".
    public var title: String
    /// Why it needs attention, for example the guardrail that held it.
    public var reason: String
    public var link: Link
    public var time: TimeText
}

/// One ledger event for the inspector.
public struct EventDetail: Sendable, Hashable, Codable {
    /// Where the event sits in its run.
    public struct RunStep: Sendable, Hashable, Codable {
        public var run: String
        /// Position among the run's events, from 1, and how many the run has.
        public var index: Int
        public var count: Int
        /// The run's title.
        public var title: String
    }

    public var entry: LedgerEntry
    /// The payload as indented canonical JSON, for reading.
    public var payloadText: String
    /// This event's hash and the previous event's hash it chains to.
    public var hash: String
    public var prev: String
    public var time: TimeText
    public var step: RunStep?
}

extension Workspace {
    /// The workspace clock's current time (the real clock, or a test's fixed one).
    public func now() -> Date { ambient.now().date }

    /// `date` as relative and absolute text against the workspace clock.
    public func timeText(_ date: Date, timeZone: TimeZone = .current) -> TimeText {
        TimeText(date, now: now(), timeZone: timeZone)
    }

    /// Everything waiting on a person, newest first: pending approvals, stewards whose newest
    /// run failed, and stewards whose newest rehearsal is stale.
    public func needsYou(timeZone: TimeZone = .current) async throws -> [NeedsYouItem] {
        let now = now()
        func time(_ date: Date) -> TimeText { TimeText(date, now: now, timeZone: timeZone) }
        var items: [NeedsYouItem] = []
        for approval in try await approvals() {
            let what =
                approval.kind == .question
                ? "Question: \(approval.text)"
                : "\(Self.capitalized(approval.actionKind ?? "action"))"
                    + (approval.target.map { " \($0)" } ?? "")
            items.append(
                NeedsYouItem(
                    kind: .approval, steward: approval.steward, title: Self.trimmed(what),
                    reason: approval.policyText ?? "Waiting for approval.",
                    link: .init(kind: "approval", id: approval.id),
                    time: time(approval.requestedAt)))
        }
        let stewards = try await stewardBook().all.filter { $0.status != .retired }
        let runs = try await runBook().all.filter { $0.trigger != "case" && $0.parent == nil }
        for steward in stewards {
            guard let newest = runs.last(where: { $0.steward == steward.id }),
                newest.status == .failed
            else { continue }
            let summary = RunSummary(newest)
            items.append(
                NeedsYouItem(
                    kind: .failedRun, steward: steward.id.rawValue, title: summary.title,
                    reason: "Run failed: \(newest.failureReason ?? "unknown")",
                    link: .init(kind: "run", id: newest.id.rawValue),
                    time: time(summary.endedAt ?? summary.startedAt)))
        }
        items += try await staleRehearsals(stewards, time: time)
        return items.sorted { $0.time.date > $1.time.date }
    }

    private func staleRehearsals(
        _ stewards: [StewardRecord], time: (Date) -> TimeText
    ) async throws -> [NeedsYouItem] {
        let state = try facadeState()
        let book = state.rehearsals
        let casebooks = try await casebookIndex()
        var items: [NeedsYouItem] = []
        for steward in stewards {
            guard let casebook = casebooks.last(where: { $0.steward == steward.id.rawValue })
            else { continue }
            let newest = book.finished(steward: steward.id).first { $0.request.proposal == nil }
            let reason: String
            var since = casebook.importedAt
            if let newest {
                if newest.request.charterVersion != steward.version {
                    reason = "Charter v\(steward.version) has not been rehearsed."
                    since = state.charterChanged[steward.id] ?? since
                } else if newest.request.casebookVersion != casebook.version {
                    reason = "The newest casebook has not been rehearsed."
                } else {
                    continue
                }
            } else {
                reason = "Never rehearsed on \(casebook.name)."
            }
            items.append(
                NeedsYouItem(
                    kind: .staleRehearsal, steward: steward.id.rawValue,
                    title: "Rehearse \(steward.charter.name)", reason: reason,
                    link: .init(kind: "rehearsals", id: steward.id.rawValue),
                    time: time(since)))
        }
        return items
    }

    /// One ledger event for the inspector, or `nil` when no event has this `seq`.
    public func event(seq: Int, timeZone: TimeZone = .current) async throws -> EventDetail? {
        let state = try facadeState()
        guard let event = state.event(seq: seq) else { return nil }
        var step: EventDetail.RunStep?
        if let run = event.run {
            let own = state.byRun[run] ?? []
            let index = (own.firstIndex { $0.seq == event.seq } ?? 0) + 1
            let title = try await runBook().records[run].map { RunSummary($0).title } ?? ""
            step = .init(run: run.rawValue, index: index, count: own.count, title: title)
        }
        return EventDetail(
            entry: try LedgerEntry(event), payloadText: Self.pretty(event.payload),
            hash: event.hash, prev: event.prev, time: timeText(event.at.date, timeZone: timeZone),
            step: step)
    }

    static func pretty(_ value: JSONValue) -> String {
        guard let data = try? CanonicalJSON.encode(value),
            let object = try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed]),
            let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]),
            let text = String(data: pretty, encoding: .utf8)
        else { return (try? CanonicalJSON.string(value)) ?? "" }
        return text
    }

    static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    static func trimmed(_ text: String, limit: Int = 60) -> String {
        RunSummary.title(summary: text, input: "", limit: limit)
    }
}
