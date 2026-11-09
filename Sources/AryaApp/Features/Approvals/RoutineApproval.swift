import AryaDesign
import SwiftUI

/// What a routine approval asks about: the routine version the run would execute, and the
/// last version of the same routine a person approved, if any (decision 0032).
struct RoutineApprovalSubject: Hashable, Sendable {
    var steward: String
    var name: String
    var version: String
    var previousApproved: String?

    /// The subject of approval `id`, when it holds a `routine` action naming its routine. The
    /// version is the routine's live version when the run started, as the runtime decides.
    static func find(events: [FeatureEvent], approval id: String) -> RoutineApprovalSubject? {
        guard
            let request = events.first(where: {
                $0.type == "approval.requested" && $0.payload["approval"]?.string == id
            }),
            let steward = request.steward, let run = request.run,
            let name = routineName(request.payload["action"]),
            let version = liveVersion(events: events, steward: steward, name: name, run: run)
        else { return nil }
        let granted = Set(
            events.filter { $0.type == "approval.granted" && $0.seq < request.seq }
                .compactMap { $0.payload["approval"]?.string })
        let previous = events.filter {
            $0.type == "approval.requested" && $0.seq < request.seq && $0.steward == steward
                && granted.contains($0.payload["approval"]?.string ?? "")
                && routineName($0.payload["action"]) == name
        }
        .compactMap { event in
            event.run.flatMap {
                liveVersion(events: events, steward: steward, name: name, run: $0)
            }
        }
        .last { $0 != version }
        return RoutineApprovalSubject(
            steward: steward, name: name, version: version, previousApproved: previous)
    }

    private static func routineName(_ action: FeatureJSON?) -> String? {
        guard let action, action["kind"]?.string == "routine" else { return nil }
        return action["params"]?["name"]?.string
    }

    /// The live version of a routine just before the run's `run.started`.
    private static func liveVersion(
        events: [FeatureEvent], steward: String, name: String, run: String
    ) -> String? {
        guard let start = events.first(where: { $0.type == "run.started" && $0.run == run })
        else { return nil }
        let before = events.filter { $0.seq < start.seq }
        return RoutineList.build(events: before, steward: steward).routines
            .first { $0.name == name }?.live
    }
}

/// A charter proposal that lets a routine version run without asking: the live charter plus
/// the policy rule `routine:<name>@<version>: auto` (decision 0032).
enum RoutineAllowance {
    static func rule(_ subject: RoutineApprovalSubject) -> String {
        "routine:\(subject.name)@\(subject.version)"
    }

    /// Nil without a live charter, or when the charter already decides this version.
    static func proposal(events: [FeatureEvent], subject: RoutineApprovalSubject)
        -> CharterProposal?
    {
        guard let live = LiveCharter.find(events: events, steward: subject.steward) else {
            return nil
        }
        var draft = CharterDraft(charter: live.charter)
        let action = rule(subject)
        if draft.policyRules.contains(where: { $0.action == action }) { return nil }
        draft.policyRules.append(
            PolicyRuleDraft(key: draft.makeKey(), action: action, decision: "auto"))
        return CharterProposal(
            steward: subject.steward, baseVersion: live.version, charter: draft.charter,
            title: "Allow routine \(subject.name) \(RoutinesText.shortVersion(subject.version))",
            reason: "Let this routine version run without asking.")
    }
}

/// What the routine detail under an approval card shows.
enum RoutineApprovalState: Hashable, Sendable {
    case loading
    /// The body of the asked-about version, and its diff from the last approved one.
    case loaded(body: String, diff: String?)
    case failed(String)
}

/// Loads the body and diff for a routine approval.
enum RoutineApprovalLoader {
    static func load(_ workspace: any FeatureWorkspace, _ subject: RoutineApprovalSubject) async
        -> RoutineApprovalState
    {
        do {
            guard
                let body = try await workspace.routineContent(
                    steward: subject.steward, name: subject.name, version: subject.version)
            else {
                return .failed(
                    "The body of \(RoutinesText.shortVersion(subject.version)) is missing.")
            }
            guard let previous = subject.previousApproved,
                let old = try await workspace.routineContent(
                    steward: subject.steward, name: subject.name, version: previous)
            else { return .loaded(body: body, diff: nil) }
            let diff = LineDiff.unified(
                old: old, new: body,
                oldLabel: "\(subject.name) \(RoutinesText.shortVersion(previous)) (approved)",
                newLabel: "\(subject.name) \(RoutinesText.shortVersion(subject.version))")
            return .loaded(body: body, diff: diff.isEmpty ? nil : diff)
        } catch {
            return .failed(FeatureStore.describe(error))
        }
    }
}

/// The routine an approval would run: its exact version and what changed since the last one a
/// person approved.
struct RoutineApprovalDetail: View {
    @ObservedObject var store: FeatureStore
    var subject: RoutineApprovalSubject
    @AryaState private var state = RoutineApprovalState.loading

    var body: some View {
        DisclosureGroup {
            content.padding(.top, AryaSpace.s2)
        } label: {
            Text(RoutineApprovalText.title(subject)).aryaText(AryaFont.caption, AryaColor.inkMuted)
        }
        .task(id: subject) { state = await RoutineApprovalLoader.load(store.workspace, subject) }
    }

    @ViewBuilder private var allowance: some View {
        if case .loaded(let events) = store.state,
            let proposal = RoutineAllowance.proposal(events: events, subject: subject)
        {
            Button("Always allow this version") {
                Task { await store.perform(.proposeCharter(proposal)) }
            }
            .buttonStyle(.aryaTertiary)
            .help("Propose a charter change so this exact version runs without asking.")
        }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .loading:
            Text("Loading the routine.").aryaText(AryaFont.caption, AryaColor.inkFaint)
        case .failed(let message):
            Text(message).aryaText(AryaFont.caption, AryaColor.negative)
        case .loaded(let body, let diff):
            VStack(alignment: .leading, spacing: AryaSpace.s2) {
                if let diff {
                    Text("Changes since the approved version")
                        .aryaText(AryaFont.caption, AryaColor.inkMuted)
                    DiffBlock(diff)
                }
                Text("Full body").aryaText(AryaFont.caption, AryaColor.inkMuted)
                CodeBlock(body)
                allowance
            }
        }
    }
}

/// Text for routine approvals, kept apart from layout so it can be tested.
enum RoutineApprovalText {
    /// "Routine label-duplicates 4d5e6f, changed since approved 1a2b3c".
    static func title(_ subject: RoutineApprovalSubject) -> String {
        let version = "Routine \(subject.name) \(RoutinesText.shortVersion(subject.version))"
        guard let previous = subject.previousApproved else {
            return version + ", never approved before"
        }
        return version + ", changed since approved \(RoutinesText.shortVersion(previous))"
    }
}
