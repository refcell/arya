import Arya
import AryaDesign
import SwiftUI

/// The Routines library: every routine across stewards, one row each with its live version,
/// the stewards that run it, its pass rate and last run, and runs per day. Selecting a row
/// shows its versions, a diff, and Use in steward… in the inspector.
struct RoutinesLibraryView: View {
    @ObservedObject var store: FeatureStore
    let stewards: [StewardSummary]
    let selected: String?
    let select: (String) -> Void

    var body: some View {
        let library = RoutineLibrary(events: store.events, now: store.now)
        ScrollView {
            VStack(alignment: .leading, spacing: AryaSpace.s4) {
                PageTitle(
                    title: "Routines",
                    subtitle: "Every routine across stewards: who runs it, how often it passes, "
                        + "and its versions.")
                if library.entries.isEmpty {
                    EmptyState(
                        "No routines yet.",
                        guidance: "When a steward repeats work, it proposes a routine here.")
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(library.entries) { entry in
                        row(entry)
                        AryaHairline()
                    }
                }
            }
            .padding(.horizontal, AryaSize.pagePadding)
            .padding(.top, AryaSize.titleBarInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel("Routines")
    }

    private func row(_ entry: RoutineLibrary.Entry) -> some View {
        let on = selected == entry.name
        let names = entry.uses.compactMap(\.steward).map(name)
        return VStack(alignment: .leading, spacing: AryaSpace.s1) {
            HStack(alignment: .center, spacing: AryaSpace.s3) {
                Text(entry.name).aryaText(AryaFont.monoStrong, AryaColor.ink)
                Text(RoutineLibraryText.version(entry))
                    .aryaText(
                        AryaFont.monoSmall,
                        entry.live.isEmpty ? AryaColor.inkFaint : AryaColor.positive)
                Spacer(minLength: AryaSpace.s3)
                Sparkline(entry.daily).accessibilityLabel("Runs per day this week")
                Text(RoutineLibraryText.runs(entry))
                    .aryaText(
                        AryaFont.monoSmall,
                        (entry.passRate ?? 1) < 0.8 ? AryaColor.warning : AryaColor.inkMuted)
                Text(entry.lastRun.map { FeatureTime.relative($0, now: store.now) } ?? "—")
                    .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                    .frame(minWidth: 44, alignment: .trailing)
            }
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s4) {
                Text("used by " + RosterText.names(names))
                    .aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                let versions = Set(entry.uses.flatMap(\.versions)).count
                Text(versions == 1 ? "1 version" : "\(versions) versions")
                    .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                if let summary = entry.uses.flatMap(\.history).last(where: { !$0.summary.isEmpty })?
                    .summary
                {
                    Text(summary).aryaText(AryaFont.caption, AryaColor.inkFaint)
                }
            }
            .lineLimit(1)
        }
        .padding(.vertical, AryaSpace.s2)
        .padding(.horizontal, AryaSpace.s2)
        .background(
            on ? AryaColor.selection : Color.clear,
            in: RoundedRectangle(cornerRadius: AryaRadius.small)
        )
        .contentShape(Rectangle())
        .onTapGesture { select(entry.name) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func name(_ id: String) -> String { stewards.first { $0.id == id }?.name ?? id }
}

/// The inspector for a routine in the library: each steward's live version, the newest diff,
/// its history, and Use in steward… (proposed there and gated on that steward's casebook).
struct RoutineInspector: View {
    @ObservedObject var store: FeatureStore
    let stewards: [StewardSummary]
    let routine: String

    @AryaState private var note: String?

    var body: some View {
        let library = RoutineLibrary(events: store.events, now: store.now)
        if let entry = library.entries.first(where: { $0.name == routine })
            ?? (routine.isEmpty ? library.entries.first : nil)
        {
            content(entry)
                .task(id: entry.diffKey) { await store.loadLibraryDiff(entry) }
        } else {
            Text("No routines yet.").aryaText(AryaFont.caption, AryaColor.inkFaint)
        }
    }

    private func content(_ entry: RoutineLibrary.Entry) -> some View {
        VStack(alignment: .leading, spacing: AryaSpace.s3) {
            VStack(alignment: .leading, spacing: AryaSpace.s1) {
                Text(entry.name).aryaText(AryaFont.monoStrong, AryaColor.ink)
                Text(RoutineLibraryText.runs(entry))
                    .aryaText(AryaFont.caption, AryaColor.inkMuted)
            }
            useMenu(entry)
            if let note { Text(note).aryaText(AryaFont.caption, AryaColor.inkMuted) }
            VStack(alignment: .leading, spacing: AryaSpace.s1) {
                Text("STEWARDS").aryaText(AryaFont.label, AryaColor.inkFaint)
                ForEach(entry.uses) { use in
                    HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                        Text(name(use.steward ?? "")).aryaText(AryaFont.caption, AryaColor.ink)
                        Spacer()
                        if let newer = RoutineLibraryText.behind(use, entry) {
                            Button("Update to \(RoutinesText.shortVersion(newer.version))") {
                                adopt(entry.name, newer, into: use.steward ?? "")
                            }
                            .buttonStyle(.aryaTertiary)
                            .help("Propose the newer version; its gate decides.")
                        }
                        Text(RoutineLibraryText.pin(use))
                            .aryaText(
                                AryaFont.monoSmall,
                                use.live == nil ? AryaColor.inkFaint : AryaColor.positive)
                    }
                    .accessibilityElement(children: .contain)
                }
            }
            VStack(alignment: .leading, spacing: AryaSpace.s1) {
                Text("VERSION DIFF").aryaText(AryaFont.label, AryaColor.inkFaint)
                switch diffState(entry) {
                case .diff(let text): DiffBlock(text)
                case .identical:
                    Text("The two newest versions are the same.")
                        .aryaText(AryaFont.caption, AryaColor.inkFaint)
                case .missing(let version):
                    Text("Version \(RoutinesText.shortVersion(version)) is not in this home.")
                        .aryaText(AryaFont.caption, AryaColor.inkFaint)
                case .failed(let problem):
                    Text(problem).aryaText(AryaFont.caption, AryaColor.inkFaint)
                case .loading:
                    Text("Loading…").aryaText(AryaFont.caption, AryaColor.inkFaint)
                case nil:
                    Text("One version so far.").aryaText(AryaFont.caption, AryaColor.inkFaint)
                }
            }
            VStack(alignment: .leading, spacing: AryaSpace.s1) {
                Text("HISTORY").aryaText(AryaFont.label, AryaColor.inkFaint)
                let history = entry.uses.flatMap { use in use.history.map { (use, $0) } }
                    .sorted { $0.1.at > $1.1.at }.prefix(6)
                ForEach(Array(history.enumerated()), id: \.offset) { _, pair in
                    Text(
                        "\(name(pair.0.steward ?? "")): \(RoutinesText.history(pair.1))"
                            + " · \(FeatureTime.relative(pair.1.at, now: store.now))"
                    )
                    .aryaText(AryaFont.caption, AryaColor.inkMuted)
                    .lineLimit(2)
                }
            }
        }
    }

    /// Use in steward…: a steward without it gets the newest live version as a proposal that
    /// goes live only through its own routine gate.
    @ViewBuilder
    private func useMenu(_ entry: RoutineLibrary.Entry) -> some View {
        let have = Set(entry.uses.compactMap(\.steward))
        let others = stewards.filter { !have.contains($0.id) }
        if let source = entry.source, !others.isEmpty {
            Menu {
                ForEach(others, id: \.id) { steward in
                    Button(steward.name) { adopt(entry.name, source, into: steward.id) }
                }
            } label: {
                Text("Use in steward… ▾").aryaText(AryaFont.body, AryaColor.ink)
            }
            .aryaMenuButton()
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Propose this routine to another steward; its gate decides.")
        }
    }

    /// Proposes `source`'s version to `target`; its gate decides whether it goes live.
    private func adopt(
        _ routine: String, _ source: (steward: String, version: String), into target: String
    ) {
        Task {
            let done = await store.perform(
                .adoptRoutine(
                    name: routine, version: source.version, from: source.steward, into: target))
            note =
                done
                ? "Proposed \(RoutinesText.shortVersion(source.version)) to \(name(target)); it "
                    + "goes live only if its casebook still passes." : nil
        }
    }

    private func diffState(_ entry: RoutineLibrary.Entry) -> RoutineDiffState? {
        guard let key = entry.diffKey else { return nil }
        return store.libraryDiffs[key] ?? .loading
    }

    private func name(_ id: String) -> String { stewards.first { $0.id == id }?.name ?? id }
}
