import Foundation

/// GETTING TO KNOW YOUR TEAM: the four steps a new steward takes before it goes live, grouped
/// from the workspace's onboarding steps. It reads its systems (people, queues, and routing
/// notes), learns from past work (history imported as cases), a person reviews what it would
/// have done, and the go-live gate lets the person mark it ready.
struct OnboardingSteps: Hashable, Sendable {
    enum Stage: Int, Hashable, Sendable { case systems, learn, review, live }

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
    /// The notes its onboard run wrote, newest last.
    var notes: [FeatureOnboarding.Note]
    /// Bindings that can page their past items (`history` among their reads).
    var historyBindings: [String]
    /// Mark ready is enabled only when the go-live gate passes; otherwise its sentence shows.
    var gate: FeatureGoLiveGate?
    /// The finished rehearsal of the live charter, which Mark ready records.
    var rehearsal: String?
    var charterVersion: Int?

    var canMarkReady: Bool { gate?.ready == true && rehearsal != nil && charterVersion != nil }

    /// What onboarding read from past records first ("Read 412 past records → 18 notes."),
    /// then each connection's history ("Inbox: 412 records (Aug 2 to Nov 10), up to date."),
    /// then the history step's own words.
    static func learnDetail(
        _ line: String?, _ rest: String, read: [FeatureIngestion] = []
    ) -> String {
        ([line.map { $0 + "." }] + read.map { Optional($0.sentence) } + [rest.isEmpty ? nil : rest])
            .compactMap { $0 }.joined(separator: " ")
    }

    static func build(
        onboarding: FeatureOnboarding, gate: FeatureGoLiveGate?, events: [FeatureEvent],
        steward: String
    ) -> OnboardingSteps {
        let live = LiveCharter.find(events: events, steward: steward)
        let bindings = (live?.charter["bindings"]?.array ?? []).compactMap { binding -> String? in
            guard let id = binding["id"]?.string,
                (binding["read"]?.array ?? []).contains(where: { $0.string == "history" })
            else { return nil }
            return id
        }
        func done(_ key: String) -> Bool { onboarding.step(key)?.done ?? false }
        let names = OutcomePeople.names(events: events, steward: steward)
        func detail(_ key: String) -> String {
            OutcomePeople.humanize(onboarding.step(key)?.detail ?? "", names: names)
        }
        let read = ["systems", "people", "processes", "notes"]
        let systemsDetail =
            done("notes")
            ? [detail("notes"), detail("people")].joined(separator: " ")
            : read.first { !done($0) }.map(detail) ?? ""
        let steps = [
            Step(
                stage: .systems, title: "Read your systems", detail: systemsDetail,
                done: read.allSatisfy(done)),
            Step(
                stage: .learn, title: "Learn from past work",
                detail: learnDetail(
                    onboarding.historyLine,
                    done("history") || bindings.isEmpty
                        ? detail("history")
                        : "Import past items from \(bindings.joined(separator: ", ")).",
                    read: onboarding.ingestion.filter { $0.records > 0 || $0.lastError != nil }),
                done: done("history") || onboarding.historyLine != nil),
            Step(
                stage: .review, title: "Review what it would have done", detail: detail("review"),
                done: done("review")),
            Step(
                stage: .live, title: "Rehearse and go live",
                detail: gate?.summary ?? detail("ready"), done: done("ready")),
        ]
        let version = live?.version
        let started = events.last {
            $0.steward == steward && $0.type == "rehearsal.started"
                && Int($0.payload["charterVersion"]?.number ?? -1) == version
                && $0.payload["proposal"] == nil
        }
        let id = started?.payload["rehearsal"]?.string
        let finished = events.contains {
            $0.type == "rehearsal.finished" && id != nil && $0.payload["rehearsal"]?.string == id
        }
        return OnboardingSteps(
            steps: steps, current: steps.first { !$0.done }?.stage,
            notes: onboarding.notes.map {
                .init(
                    about: OutcomePeople.humanize($0.about, names: names),
                    text: OutcomePeople.humanize($0.text, names: names))
            },
            historyBindings: bindings, gate: gate, rehearsal: finished ? id : nil,
            charterVersion: version)
    }
}
