import AryaCore
import AryaRuntime

/// Why a steward is not ready, for the outcome screen's "not ready because…".
public struct ReadinessReason: Hashable, Sendable, Codable {
    /// Stable code: `no_rehearsal`, `stale_rehearsal`, `below_threshold`, `leaks`,
    /// `regressions`, `corrections_outstanding`.
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// Whether the live charter is ready to go live, and why not. `ready` means the evidence
/// supports it; `markedReady` means a person recorded `steward.ready` for the live version.
/// A person still decides (readiness never requires a rehearsal to be marked).
public struct ReadinessReport: Hashable, Sendable, Codable {
    public var steward: StewardID
    public var charterVersion: Int
    public var ready: Bool
    public var markedReady: Bool
    public var reasons: [ReadinessReason]
    /// The latest finished rehearsal of the live charter (no proposal, no candidate routine).
    public var rehearsal: RehearsalID?
    public var lastRehearsalAt: Timestamp?
    /// Cases that passed in every sample over all cases; `nil` without a rehearsal.
    public var passRate: Double?
    public var passed: Int
    public var total: Int
    public var threshold: Double
    public var meanScore: Double?
    public var leaks: Int
    /// Cases that passed in the previous live rehearsal on the same casebook and now fail.
    public var regressions: [CaseID]
    /// Corrections recorded since the latest rehearsal finished.
    public var correctionsOutstanding: Int
}

/// Builds `ReadinessReport`s from the ledger.
public struct ReadinessReports: Sendable {
    public var sink: any EventSink

    public init(sink: any EventSink) {
        self.sink = sink
    }

    /// `threshold` is the pass rate required, in `0...1`; by default every case must pass.
    public func report(_ steward: StewardID, threshold: Double = 1) async throws
        -> ReadinessReport
    {
        let events = try await sink.events(from: 1)
        guard let live = try StewardBook(events).records[steward] else {
            throw StewardError.notFound(steward)
        }
        let changed =
            events.last {
                $0.draft.steward == steward && GateFlow.configurationTypes.contains($0.type)
            }?.seq ?? 0
        let runs = try RehearsalBook(events).records.values
            .filter {
                let request = $0.result.request
                return $0.finished && request.steward == steward && request.proposal == nil
                    && request.routine == nil
            }
            .sorted { ($0.finishedSeq ?? 0) > ($1.finishedSeq ?? 0) }
        let latest = runs.first
        let previous = latest.flatMap { latest in
            runs.dropFirst().first {
                $0.result.request.casebookVersion == latest.result.request.casebookVersion
            }
        }
        let after = latest?.finishedSeq ?? 0
        var report = ReadinessReport(
            steward: steward, charterVersion: live.version, ready: false,
            markedReady: try Self.marked(events, steward, live.version), reasons: [],
            rehearsal: latest?.result.id,
            lastRehearsalAt: events.first { $0.seq == latest?.finishedSeq }?.at, passRate: nil,
            passed: 0, total: 0, threshold: threshold, meanScore: nil, leaks: 0,
            regressions: [],
            correctionsOutstanding: events.filter {
                $0.type == EvalEventType.caseCorrected && $0.draft.steward == steward
                    && $0.seq > after
            }.count)
        if let latest {
            Self.measure(&report, latest, previous, stale: Self.stale(latest, live, changed))
        }
        report.reasons = Self.reasons(report, rehearsed: latest != nil)
        report.ready = report.reasons.isEmpty
        return report
    }

    static func stale(_ latest: RehearsalRecord, _ live: StewardRecord, _ changed: Int) -> Bool {
        latest.result.request.charterVersion != live.version || (latest.finishedSeq ?? 0) < changed
    }

    static func measure(
        _ report: inout ReadinessReport, _ latest: RehearsalRecord, _ previous: RehearsalRecord?,
        stale: Bool
    ) {
        let outcomes = latest.result.outcomes
        report.total = outcomes.count
        report.passed = outcomes.filter(GateRule.alwaysPassed).count
        report.passRate = outcomes.isEmpty ? 0 : Double(report.passed) / Double(report.total)
        report.meanScore = GateRule.mean(latest.result)
        report.leaks = outcomes.filter(\.leak).count
        if let previous {
            report.regressions =
                GateRule.evaluate(
                    baseline: previous.result, candidate: latest.result, tolerance: .infinity
                ).regressions
        }
        if stale { report.reasons.append(Self.staleReason) }
    }

    static let staleReason = ReadinessReason(
        code: "stale_rehearsal",
        message: "The charter or its routines changed since the last rehearsal.")

    static func reasons(_ report: ReadinessReport, rehearsed: Bool) -> [ReadinessReason] {
        guard rehearsed, let rate = report.passRate else {
            return [ReadinessReason(code: "no_rehearsal", message: "No rehearsal yet.")]
        }
        var out = report.reasons
        if rate < report.threshold {
            out.append(
                ReadinessReason(
                    code: "below_threshold",
                    message: "\(report.passed) of \(report.total) cases pass; "
                        + "\(percent(report.threshold)) required."))
        }
        if report.leaks > 0 {
            out.append(
                ReadinessReason(
                    code: "leaks", message: "\(report.leaks) case(s) read outside the case."))
        }
        if !report.regressions.isEmpty {
            let ids = report.regressions.map(\.rawValue).joined(separator: ", ")
            out.append(ReadinessReason(code: "regressions", message: "Regressed: \(ids)."))
        }
        if report.correctionsOutstanding > 0 {
            out.append(
                ReadinessReason(
                    code: "corrections_outstanding",
                    message: "\(report.correctionsOutstanding) correction(s) not yet rehearsed."))
        }
        return out
    }

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    static func marked(_ events: [RuntimeEvent], _ steward: StewardID, _ version: Int) throws
        -> Bool
    {
        try events.contains { event in
            guard event.type == StewardEventType.ready, event.draft.steward == steward else {
                return false
            }
            return try EvalPayload.decode(StewardReadyPayload.self, event.payload).charterVersion
                == version
        }
    }
}
