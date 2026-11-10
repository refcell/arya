import AryaCore
import Foundation

/// Runs per local day, the one source for run-count bars (portfolio RUNS 7D, inspector RUNS ·
/// 7 DAYS). Counts top-level live runs: rehearsal case runs and crew children are kept apart,
/// so a rehearsal burst does not flatten the bars.
public struct RunHistory: Sendable, Hashable, Codable {
    public struct Day: Sendable, Hashable, Codable {
        /// Local midnight.
        public var start: Date
        /// Top-level live runs started that day.
        public var runs: Int
        /// Of those, the ones that failed.
        public var failed: Int
        /// Rehearsal case runs started that day, not in `runs`.
        public var rehearsals: Int
    }

    /// Nil for the whole home.
    public var steward: String?
    /// Oldest first; the last is today.
    public var days: [Day]
    public var total: Int
    public var failed: Int
    public var today: Int
    /// One line, shown verbatim: `60 runs in 7 days, 17 today, 2 failed`.
    public var line: String
}

extension Workspace {
    /// Runs started on each of the last `days` local days (today last), for `steward` or the
    /// whole home.
    public func runHistory(
        steward: String? = nil, days: Int = 7, timeZone: TimeZone = .current
    ) async throws -> RunHistory {
        if let steward { _ = try await existing(steward) }
        let count = max(1, days)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now())
        var out = (0..<count).map { back in
            RunHistory.Day(
                start: calendar.date(byAdding: .day, value: back - count + 1, to: today) ?? today,
                runs: 0, failed: 0, rehearsals: 0)
        }
        for record in try await runBook().all
        where steward == nil || record.steward.rawValue == steward {
            let run = RunSummary(record)
            guard run.parent == nil else { continue }
            let day = calendar.startOfDay(for: run.startedAt)
            guard let back = calendar.dateComponents([.day], from: day, to: today).day,
                (0..<count).contains(back)
            else { continue }
            let index = count - 1 - back
            if run.trigger == "case" {
                out[index].rehearsals += 1
            } else {
                out[index].runs += 1
                if run.status == .failed { out[index].failed += 1 }
            }
        }
        let total = out.reduce(0) { $0 + $1.runs }
        let failed = out.reduce(0) { $0 + $1.failed }
        let todayRuns = out.last?.runs ?? 0
        var line = "\(Self.count(total, "run", "runs")) in \(Self.count(count, "day", "days"))"
        line += ", \(todayRuns) today"
        if failed > 0 { line += ", \(failed) failed" }
        return RunHistory(
            steward: steward, days: out, total: total, failed: failed, today: todayRuns,
            line: line)
    }
}
