import Foundation

/// GETTING TO KNOW YOUR TEAM: the three steps a new steward takes before it goes live. It
/// learns from past work (history imported into a casebook), a person reviews what it would
/// have done, and a passing rehearsal lets the person mark it ready.
struct OnboardingSteps: Hashable, Sendable {
    enum Stage: Int, Hashable, Sendable { case learn, review, live }

    struct Step: Hashable, Sendable, Identifiable {
        var stage: Stage
        var title: String
        var detail: String
        var done: Bool
        var id: Int { stage.rawValue }
    }

    var steps: [Step]
    /// The first step not done; nil once the steward is ready.
    var current: Stage?
    /// Bindings that can page their past items (`history` among their reads).
    var historyBindings: [String]
    /// The finished rehearsal of the live charter, when there is one, for Mark ready.
    var rehearsal: String?
    var charterVersion: Int?
    /// The rehearsal passed every case, so Mark ready is the primary action.
    var passed = false

    static func build(
        events: [FeatureEvent], steward: String, queue: FeatureReviewQueue?
    ) -> OnboardingSteps {
        let live = LiveCharter.find(events: events, steward: steward)
        let bindings = (live?.charter["bindings"]?.array ?? []).compactMap { binding -> String? in
            guard let id = binding["id"]?.string,
                (binding["read"]?.array ?? []).contains(where: { $0.string == "history" })
            else { return nil }
            return id
        }
        let readiness = OutcomeReadiness.build(events: events, steward: steward)
        let total = queue?.total ?? 0
        let learned = total > 0
        let learnDetail =
            learned
            ? "\(total) past \(total == 1 ? "item" : "items") in casebook "
                + (queue?.casebookVersion ?? "")
            : bindings.isEmpty
                ? "No connection here can list past items; add cases in Improve."
                : "Import past items from \(bindings.joined(separator: ", "))."
        let reviewed = learned && (queue?.reviewed ?? 0) >= total
        let reviewDetail =
            learned
            ? (queue?.progressText ?? "")
            : "Once past items are in, compare what it would have done with what you did."
        // The rehearsal of the live charter, when one finished.
        let version = live?.version
        let started = events.last {
            $0.steward == steward && $0.type == "rehearsal.started"
                && Int($0.payload["charterVersion"]?.number ?? -1) == version
                && $0.payload["proposal"] == nil
        }
        let id = started?.payload["rehearsal"]?.string
        let finished = events.last {
            $0.type == "rehearsal.finished" && id != nil && $0.payload["rehearsal"]?.string == id
        }
        let cases = Int(started?.payload["cases"]?.number ?? 0)
        let passedCount = Int(finished?.payload["passed"]?.number ?? 0)
        let liveDetail: String =
            switch readiness {
            case .ready(let version): "Live on charter v\(version)."
            case .notReady(let reason): "Not ready: \(reason)."
            }
        let steps = [
            Step(stage: .learn, title: "Learn from past work", detail: learnDetail, done: learned),
            Step(
                stage: .review, title: "Review what it would have done", detail: reviewDetail,
                done: reviewed),
            Step(
                stage: .live, title: "Rehearse and go live", detail: liveDetail,
                done: readiness.isReady),
        ]
        return OnboardingSteps(
            steps: steps, current: steps.first { !$0.done }?.stage, historyBindings: bindings,
            rehearsal: finished == nil ? nil : id, charterVersion: version,
            passed: finished != nil && cases > 0 && passedCount == cases)
    }
}
