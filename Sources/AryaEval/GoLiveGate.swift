import AryaCore

/// One condition of the go-live gate.
public struct GoLiveCondition: Hashable, Sendable, Codable {
    /// `review`, `rehearsal`, or `checks`.
    public var key: String
    public var met: Bool
    /// One line, shown verbatim: `6 of 10 agreed reviews` or `misses “…” on case-0006`.
    public var detail: String
}

/// Whether a steward is ready to go live after onboarding: a person agreed with enough of
/// what it would have done, its latest live rehearsal passes, and every check people taught it
/// is rehearsed and green. A person still decides; the gate only says what the evidence shows.
public struct GoLiveGateResult: Hashable, Sendable, Codable {
    public var steward: String
    public var ready: Bool
    /// Review, rehearsal, then checks; each is reported even when an earlier one fails.
    public var conditions: [GoLiveCondition]
    /// Agreements needed: the requested number, or every case when the queue is smaller.
    public var agreedNeeded: Int
    /// One sentence, shown verbatim: `Ready to go live: 10 agreed, 34/34 passed, checks green.`
    /// or `Not ready: 4 more agreed reviews needed; 2 checks fail.`
    public var summary: String
}

/// Builds the go-live gate from the review queue, the readiness report, and learned checks.
public enum GoLiveGate {
    /// Default agreements a person gives before a steward goes live.
    public static let defaultAgreed = 10

    public static func evaluate(
        steward: String, review: ReviewQueueView?, readiness: ReadinessReport,
        checks: LearnedChecksView?, agreed needed: Int = defaultAgreed
    ) -> GoLiveGateResult {
        let total = review?.total ?? 0
        let need = max(1, min(needed, total))
        let agreed = review?.agreed ?? 0
        let reviewMet = total > 0 && agreed >= need
        let reviewDetail =
            total == 0
            ? "no history to review yet"
            : "\(agreed) of \(need) agreed review\(need == 1 ? "" : "s")"

        let rehearsalDetail =
            readiness.ready
            ? "\(readiness.passed)/\(readiness.total) passed, no regressions"
            : readiness.reasons.first?.message ?? "no rehearsal yet"

        let failing = checks.map { $0.scored - $0.passed } ?? 0
        let unscored = checks.map { $0.total - $0.scored } ?? 0
        let checksMet = (checks?.total ?? 0) > 0 && failing == 0 && unscored == 0
        let checksDetail: String
        if (checks?.total ?? 0) == 0 {
            checksDetail = "no checks yet; agree with or correct reviews"
        } else if failing > 0 {
            checksDetail =
                checks?.results.first { $0.passed == false }?.result
                ?? "\(failing) check\(failing == 1 ? "" : "s") fail"
        } else if unscored > 0 {
            checksDetail = "\(unscored) check\(unscored == 1 ? "" : "s") not rehearsed yet"
        } else {
            checksDetail = "all \(checks?.total ?? 0) checks pass"
        }

        let conditions = [
            GoLiveCondition(key: "review", met: reviewMet, detail: reviewDetail),
            GoLiveCondition(key: "rehearsal", met: readiness.ready, detail: rehearsalDetail),
            GoLiveCondition(key: "checks", met: checksMet, detail: checksDetail),
        ]
        let ready = conditions.allSatisfy(\.met)
        var missing: [String] = []
        if !reviewMet {
            missing.append(
                total == 0
                    ? "import history to review"
                    : "\(need - agreed) more agreed review\(need - agreed == 1 ? "" : "s") needed")
        }
        if !readiness.ready { missing.append(rehearsalDetail) }
        if !checksMet {
            missing.append(
                failing > 0
                    ? "\(failing) check\(failing == 1 ? "" : "s") fail"
                    : (checks?.total ?? 0) == 0 ? "no checks yet" : checksDetail)
        }
        let summary =
            ready
            ? "Ready to go live: \(agreed) agreed, \(rehearsalDetail), checks green."
            : "Not ready: \(missing.joined(separator: "; "))."
        return GoLiveGateResult(
            steward: steward, ready: ready, conditions: conditions, agreedNeeded: need,
            summary: summary)
    }
}
