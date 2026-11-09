import AryaDesign
import SwiftUI

/// A steward at a glance: charter version, readiness, last run, and what waits on people.
struct StewardOverview: Hashable, Sendable {
    var charterVersion: Int?
    var ready: Bool
    var lastRun: String?
    var lastRunStatus: String?
    var waitingApprovals: Int
    var waitingQuestions: Int
    var openProposals: Int

    static func build(events: [FeatureEvent], steward: String) -> StewardOverview {
        let mine = events.filter { $0.steward == steward }
        let live = LiveCharter.find(events: events, steward: steward)?.version
        let ready = mine.contains {
            $0.type == "steward.ready" && Int($0.payload["charterVersion"]?.number ?? -1) == live
        }
        // Rehearsal case runs (`rehearsal: true`) are not live work.
        let lastRun = mine.last {
            $0.type == "run.started" && $0.payload["rehearsal"]?.bool != true
        }?.run
        let decided = Set(
            mine.filter {
                ["approval.granted", "approval.denied", "approval.expired"].contains($0.type)
            }
            .compactMap { $0.payload["approval"]?.string })
        let waiting = mine.filter {
            $0.type == "approval.requested"
                && !decided.contains($0.payload["approval"]?.string ?? "")
        }
        let toPeople = waiting.filter { $0.payload["to"]?.string?.hasPrefix("person:") == true }
        let closed = Set(
            mine.filter { ["proposal.accepted", "proposal.rejected"].contains($0.type) }
                .compactMap { $0.payload["proposal"]?.string })
        let proposals = mine.filter {
            $0.type == "proposal.created" && !closed.contains($0.payload["id"]?.string ?? "")
        }
        return StewardOverview(
            charterVersion: live, ready: ready, lastRun: lastRun,
            lastRunStatus: lastRun.map { RunStream.build(events: events, run: $0).status.word },
            waitingApprovals: waiting.count - toPeople.count, waitingQuestions: toPeople.count,
            openProposals: proposals.count)
    }

    /// "Charter v1 · not ready · last run run_0002 running · 1 approval waiting".
    var summary: String {
        var parts: [String] = []
        if let charterVersion {
            parts.append("Charter v\(charterVersion)")
            parts.append(ready ? "ready" : "not ready")
        }
        if let lastRun {
            parts.append("last run \(lastRun)" + (lastRunStatus.map { " \($0)" } ?? ""))
        } else {
            parts.append("no runs yet")
        }
        func count(_ n: Int, _ one: String, _ many: String) {
            if n > 0 { parts.append("\(n) \(n == 1 ? one : many)") }
        }
        count(waitingApprovals, "approval waiting", "approvals waiting")
        count(waitingQuestions, "question for people", "questions for people")
        count(openProposals, "proposal open", "proposals open")
        return parts.joined(separator: " · ")
    }
}

/// The overview as one caption line.
struct StewardOverviewLine: View {
    @ObservedObject var store: FeatureStore
    var steward: String

    var body: some View {
        if case .loaded(let events) = store.state {
            Text(StewardOverview.build(events: events, steward: steward).summary)
                .aryaText(AryaFont.caption, AryaColor.inkMuted)
                .monospacedDigit()
        }
    }
}
