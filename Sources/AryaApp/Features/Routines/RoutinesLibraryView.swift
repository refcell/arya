import Arya
import AryaDesign
import SwiftUI

/// The Routines library: every routine across stewards on the left (live version, users,
/// pass rate, runs per day), and the selected routine's script, newest diff and run history
/// on the right. Its stewards, upgrades and Use in steward… sit in the inspector.
struct RoutinesLibraryView: View {
    @ObservedObject var store: FeatureStore
    let stewards: [StewardSummary]
    let selected: String?
    let select: (String) -> Void

    var body: some View {
        let library = RoutineLibrary(events: store.events, now: store.now)
        let current = library.entries.first { $0.name == selected } ?? library.entries.first
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
                HStack(alignment: .top, spacing: AryaSpace.s5) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(library.entries) { entry in
                            row(entry, on: entry.name == current?.name)
                            AryaHairline()
                        }
                        if !library.entries.isEmpty {
                            runsStrip(library).padding(.top, AryaSpace.s4)
                            changes(library).padding(.top, AryaSpace.s4)
                        }
                    }
                    .frame(minWidth: 320, idealWidth: 400, maxWidth: 440, alignment: .leading)
                    if let current {
                        AryaHairline(.vertical)
                        RoutineDetail(store: store, stewards: stewards, entry: current)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, AryaSize.pagePadding)
            .padding(.top, AryaSize.titleBarInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await store.loadRoutineUpgrades() }
        .accessibilityLabel("Routines")
    }

    /// Routine runs per day across the library for two weeks, passed and failed stacked.
    private func runsStrip(_ library: RoutineLibrary) -> some View {
        let days = 14
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: store.now)
        var passed = [Double](repeating: 0, count: days)
        var other = [Double](repeating: 0, count: days)
        for run in library.entries.flatMap(\.all) {
            let back =
                calendar.dateComponents([.day], from: calendar.startOfDay(for: run.at), to: today)
                .day ?? days
            guard back >= 0, back < days else { continue }
            if run.outcome == .passed {
                passed[days - 1 - back] += 1
            } else {
                other[days - 1 - back] += 1
            }
        }
        let peak = max(zip(passed, other).map(+).max() ?? 0, 1)
        let barHeight: CGFloat = 40
        let total = Int(passed.reduce(0, +) + other.reduce(0, +))
        return VStack(alignment: .leading, spacing: AryaSpace.s1) {
            HStack {
                Text("RUNS · 14 DAYS").aryaText(AryaFont.label, AryaColor.inkFaint)
                Spacer()
                Text("\(total) runs · \(Int(passed.reduce(0, +))) passed")
                    .aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
            }
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<days, id: \.self) { day in
                    VStack(spacing: 1) {
                        RoundedRectangle(cornerRadius: AryaRadius.small)
                            .fill(AryaColor.warning)
                            .frame(height: barHeight * other[day] / peak)
                        RoundedRectangle(cornerRadius: AryaRadius.small)
                            .fill(AryaColor.positive)
                            .frame(height: max(2, barHeight * passed[day] / peak))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: barHeight + 2, alignment: .bottom)
            HStack {
                Text("14d ago").aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                Spacer()
                Text("today").aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Routine runs per day for two weeks, \(total) in all")
    }

    /// Version changes across every routine, newest first: proposed, promoted, held.
    private func changes(_ library: RoutineLibrary) -> some View {
        let items = library.entries.flatMap { entry in
            entry.uses.flatMap { use in use.history.map { (entry.name, use.steward, $0) } }
        }
        .sorted { $0.2.at > $1.2.at }.prefix(8)
        return VStack(alignment: .leading, spacing: AryaSpace.s1) {
            Text("RECENT CHANGES").aryaText(AryaFont.label, AryaColor.inkFaint)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(RoutinesText.history(item.2))
                        .aryaText(AryaFont.caption, AryaColor.ink)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(
                        [item.0, item.1.map(name), FeatureTime.relative(item.2.at, now: store.now)]
                            .compactMap { $0 }.joined(separator: " · ")
                    )
                    .aryaText(AryaFont.monoSmall, AryaColor.inkFaint).lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func row(_ entry: RoutineLibrary.Entry, on: Bool) -> some View {
        let names = entry.uses.compactMap(\.steward).map(name)
        let upgrade = store.routineUpgrades.contains { $0.name == entry.name && !$0.pending }
        return VStack(alignment: .leading, spacing: AryaSpace.s1) {
            HStack(alignment: .center, spacing: AryaSpace.s2) {
                Text(entry.name).aryaText(AryaFont.monoStrong, AryaColor.ink)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Spacer(minLength: AryaSpace.s2)
                Sparkline(entry.daily).accessibilityLabel("Runs per day this week")
                Text(RoutineLibraryText.runs(entry))
                    .aryaText(
                        AryaFont.monoSmall,
                        (entry.passRate ?? 1) < 0.8 ? AryaColor.warning : AryaColor.inkMuted)
            }
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s3) {
                if upgrade { TagPill("Upgrade available") }
                Text(RoutineLibraryText.version(entry))
                    .aryaText(
                        AryaFont.monoSmall,
                        entry.live.isEmpty ? AryaColor.inkFaint : AryaColor.positive)
                Text(names.count == 1 ? names[0] : "\(names.count) stewards")
                    .aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                Spacer(minLength: AryaSpace.s2)
                Text(entry.lastRun.map { FeatureTime.relative($0, now: store.now) } ?? "—")
                    .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
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

/// The right half of the library: the live script, the newest version diff, and recent runs
/// with where each ran and how it settled.
struct RoutineDetail: View {
    @ObservedObject var store: FeatureStore
    let stewards: [StewardSummary]
    let entry: RoutineLibrary.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s4) {
            VStack(alignment: .leading, spacing: AryaSpace.s1) {
                HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                    Text(entry.name).aryaText(AryaFont.heading, AryaColor.ink)
                    Spacer()
                    TriggerStrip(
                        entry.recent.reversed().filter { $0.outcome != .waiting }
                            .map { $0.outcome == .passed })
                }
                if let summary = entry.uses.flatMap(\.history)
                    .last(where: { !$0.summary.isEmpty })?.summary
                {
                    Text(summary).aryaText(AryaFont.caption, AryaColor.inkMuted).lineLimit(2)
                }
            }
            script
            diff
            runs
        }
        .task(id: entry.diffKey) { await store.loadLibraryDiff(entry) }
        .task(id: scriptKey) {
            if let source = entry.source {
                await store.loadRoutineScript(
                    steward: source.steward, name: entry.name, version: source.version)
            }
        }
    }

    private var scriptKey: String? {
        entry.source.map { "\($0.steward)/\(entry.name)@\($0.version)" }
    }

    private var script: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            HStack(spacing: AryaSpace.s2) {
                Text("SCRIPT").aryaText(AryaFont.label, AryaColor.inkFaint)
                if let source = entry.source {
                    Text(
                        "live \(RoutinesText.shortVersion(source.version)) in "
                            + name(source.steward)
                    )
                    .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                }
            }
            if let body = scriptKey.flatMap({ store.routineScripts[$0] }) {
                CodeBlock(body.trimmingCharacters(in: .newlines))
            } else {
                Text(entry.source == nil ? "No live version yet." : "Loading…")
                    .aryaText(AryaFont.caption, AryaColor.inkFaint)
            }
        }
    }

    @ViewBuilder
    private var diff: some View {
        if let key = entry.diffKey {
            VStack(alignment: .leading, spacing: AryaSpace.s1) {
                Text("VERSION DIFF").aryaText(AryaFont.label, AryaColor.inkFaint)
                switch store.libraryDiffs[key] ?? .loading {
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
                }
            }
        }
    }

    private var runs: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("RUN HISTORY").aryaText(AryaFont.label, AryaColor.inkFaint)
                .padding(.bottom, AryaSpace.s1)
            if entry.recent.isEmpty {
                Text("Not run yet.").aryaText(AryaFont.caption, AryaColor.inkFaint)
            }
            ForEach(entry.recent) { run in
                HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s3) {
                    Text(run.outcome.rawValue)
                        .aryaText(AryaFont.monoSmall, RoutineDetail.color(run.outcome))
                        .frame(minWidth: 52, alignment: .leading)
                    Text(run.input.isEmpty ? "—" : run.input)
                        .aryaText(AryaFont.monoSmall, AryaColor.ink)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    Spacer(minLength: AryaSpace.s3)
                    Text(run.steward.map(name) ?? "")
                        .aryaText(AryaFont.caption, AryaColor.inkFaint).fixedSize()
                    Text(FeatureTime.relative(run.at, now: store.now))
                        .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                        .frame(minWidth: 44, alignment: .trailing)
                }
                .frame(minHeight: AryaSize.rowHeight)
                .accessibilityElement(children: .combine)
            }
        }
    }

    static func color(_ outcome: RoutineLibrary.Run.Outcome) -> Color {
        switch outcome {
        case .passed: AryaColor.positive
        case .failed: AryaColor.negative
        case .denied: AryaColor.warning
        case .waiting: AryaColor.inkFaint
        }
    }

    private func name(_ id: String) -> String { stewards.first { $0.id == id }?.name ?? id }
}

/// The inspector for a routine in the library: each steward's live version and upgrade,
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
                .task { await store.loadRoutineUpgrades() }
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
                        if let upgrade = store.routineUpgrades.first(where: {
                            $0.steward == use.steward && $0.name == entry.name
                        }) {
                            if upgrade.pending {
                                Text(RoutineLibraryText.upgrade(upgrade))
                                    .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                            } else {
                                Button("Upgrade") { upgradeRoutine(upgrade) }
                                    .buttonStyle(.aryaTertiary)
                                    .help(
                                        RoutineLibraryText.upgrade(upgrade) + " from "
                                            + name(upgrade.source) + "; this steward's gate "
                                            + "decides.")
                            }
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

    /// Proposes the followed steward's newer version (decision 0062) and refreshes the list.
    private func upgradeRoutine(_ upgrade: FeatureRoutineUpgrade) {
        Task {
            let done = await store.perform(
                .upgradeRoutine(steward: upgrade.steward, name: upgrade.name))
            await store.loadRoutineUpgrades()
            note =
                done
                ? "Proposed \(RoutinesText.shortVersion(upgrade.to)) to \(name(upgrade.steward)); "
                    + "it goes live only if its casebook still passes." : nil
        }
    }

    private func name(_ id: String) -> String { stewards.first { $0.id == id }?.name ?? id }
}
