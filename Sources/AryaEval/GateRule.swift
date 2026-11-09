import AryaCore

/// The pure gate rule from decision 0017.
///
/// The candidate passes when its mean score is at least the baseline mean minus `tolerance`,
/// and no case that passed in every baseline sample fails in every candidate sample. A case
/// marked `leak` counts as failed in every sample. A missing baseline or differing case sets
/// fail the gate, so a proposal never goes live untested.
public enum GateRule {
    public static func evaluate(
        baseline: RehearsalResult?, candidate: RehearsalResult, tolerance: Double
    ) -> GateVerdict {
        let candidateMean = mean(candidate)
        guard let baseline else {
            return verdict(false, nil, candidateMean, [], "no baseline rehearsal")
        }
        let baselineMean = mean(baseline)
        let ids = baseline.outcomes.map(\.caseID)
        guard ids == candidate.outcomes.map(\.caseID) else {
            return verdict(false, baselineMean, candidateMean, [], "case sets differ")
        }
        let regressions = zip(baseline.outcomes, candidate.outcomes).compactMap { old, new in
            alwaysPassed(old) && alwaysFailed(new) ? new.caseID : nil
        }
        if !regressions.isEmpty {
            return verdict(false, baselineMean, candidateMean, regressions, "case regressed")
        }
        if candidateMean < baselineMean - tolerance {
            return verdict(false, baselineMean, candidateMean, [], "mean score below baseline")
        }
        return verdict(true, baselineMean, candidateMean, [], "passed")
    }

    /// Mean over cases of each case's mean sample score; a leak or empty case scores 0.
    public static func mean(_ result: RehearsalResult) -> Double {
        guard !result.outcomes.isEmpty else { return 0 }
        let total = result.outcomes.reduce(0.0) { sum, outcome in
            guard !outcome.leak, !outcome.samples.isEmpty else { return sum }
            let caseSum = outcome.samples.reduce(0.0) { $0 + $1.value }
            return sum + caseSum / Double(outcome.samples.count)
        }
        return total / Double(result.outcomes.count)
    }

    static func alwaysPassed(_ outcome: CaseOutcome) -> Bool {
        !outcome.leak && !outcome.samples.isEmpty && outcome.samples.allSatisfy(\.passed)
    }

    static func alwaysFailed(_ outcome: CaseOutcome) -> Bool {
        outcome.leak || outcome.samples.allSatisfy { !$0.passed }
    }

    static func verdict(
        _ passed: Bool, _ baselineMean: Double?, _ candidateMean: Double, _ regressions: [CaseID],
        _ reason: String
    ) -> GateVerdict {
        GateVerdict(
            passed: passed, baselineMean: baselineMean, candidateMean: candidateMean,
            regressions: regressions, reason: reason)
    }
}
