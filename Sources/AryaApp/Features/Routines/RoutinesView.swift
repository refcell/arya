import AryaDesign
import SwiftUI

/// A steward's routines: names, live versions, history, and a diff between any two versions.
struct RoutinesView: View {
    @ObservedObject var store: FeatureStore
    var steward: String?
    @AryaState private var selected: String?

    var body: some View {
        switch store.state {
        case .loading:
            EmptyState("Loading routines.", guidance: "Reading the routine library.")
        case .failed(let message):
            EmptyState(
                "Routines could not be loaded.", guidance: message, actionTitle: "Retry",
                action: { Task { await store.reload() } })
        case .loaded(let events):
            content(RoutineList.build(events: events, steward: steward))
        }
    }

    @ViewBuilder
    private func content(_ list: RoutineList) -> some View {
        if list.routines.isEmpty {
            EmptyState(
                "No routines yet.",
                guidance: "When a steward repeats work, it proposes a routine that appears here.")
        } else {
            HStack(alignment: .top, spacing: 0) {
                RoutineNames(routines: list.routines, selected: selectedID(list))
                    .frame(width: AryaSize.railWidth)
                AryaHairline(.vertical)
                if let item = list.routines.first(where: { $0.id == selectedID(list).wrappedValue })
                {
                    RoutineDetail(item: item, store: store).id(item.id)
                }
            }
            .background(AryaColor.canvas)
        }
    }

    private func selectedID(_ list: RoutineList) -> Binding<String?> {
        Binding(
            get: { selected ?? list.routines.first?.id },
            set: { selected = $0 })
    }
}

private struct RoutineNames: View {
    var routines: [RoutineItem]
    @Binding var selected: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(routines) { item in
                    TableRowFrame(isSelected: item.id == selected) {
                        VStack(alignment: .leading, spacing: AryaSpace.s1) {
                            Text(item.name).aryaText(AryaFont.mono, AryaColor.ink)
                            Text(RoutinesText.live(item))
                                .aryaText(AryaFont.caption, AryaColor.inkFaint)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selected = item.id }
                    .accessibilityAddTraits(
                        item.id == selected ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
    }
}

private struct RoutineDetail: View {
    var item: RoutineItem
    @ObservedObject var store: FeatureStore
    @AryaState private var old: String?
    @AryaState private var new: String?
    @AryaState private var diff = RoutineDiffState.loading

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AryaSpace.s5) {
                HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s3) {
                    Text(item.name).aryaText(AryaFont.title, AryaColor.ink)
                    Chip(RoutinesText.live(item))
                }
                history
                comparison
            }
            .frame(maxWidth: AryaSize.readingWidth, alignment: .leading)
            .padding(AryaSpace.s5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: pairKey) { await loadDiff() }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            Text("History").aryaText(AryaFont.heading, AryaColor.ink)
            ForEach(Array(item.history.enumerated().reversed()), id: \.offset) { _, event in
                HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                    Text(RoutinesText.history(event)).aryaText(AryaFont.body, AryaColor.inkMuted)
                    Spacer(minLength: AryaSpace.s2)
                    Text(FeatureTime.relative(event.at, now: store.now))
                        .aryaText(AryaFont.caption, AryaColor.inkFaint)
                        .help(FeatureTime.absolute(event.at))
                }
            }
        }
    }

    @ViewBuilder private var comparison: some View {
        if item.versions.count >= 2 {
            VStack(alignment: .leading, spacing: AryaSpace.s3) {
                HStack(spacing: AryaSpace.s3) {
                    Text("Compare").aryaText(AryaFont.heading, AryaColor.ink)
                    versionPicker("From", $old, fallback: item.defaultComparison?.old)
                    versionPicker("To", $new, fallback: item.defaultComparison?.new)
                }
                diffPane
            }
        } else {
            Text("Only one version so far; a diff appears once the steward proposes another.")
                .aryaText(AryaFont.body, AryaColor.inkMuted)
        }
    }

    @ViewBuilder private var diffPane: some View {
        switch diff {
        case .loading: Text("Loading both versions.").aryaText(AryaFont.caption, AryaColor.inkFaint)
        case .diff(let text): DiffBlock(text)
        case .identical:
            Text("The two versions are identical.").aryaText(AryaFont.body, AryaColor.inkMuted)
        case .missing(let version):
            Text("Version \(RoutinesText.shortVersion(version)) is missing from the blob store.")
                .aryaText(AryaFont.body, AryaColor.negative)
        case .failed(let message): Text(message).aryaText(AryaFont.body, AryaColor.negative)
        }
    }

    private func versionPicker(
        _ title: String, _ selection: Binding<String?>, fallback: String?
    ) -> some View {
        Picker(
            title,
            selection: Binding(
                get: { selection.wrappedValue ?? fallback }, set: { selection.wrappedValue = $0 })
        ) {
            ForEach(item.versions, id: \.self) { version in
                Text(RoutinesText.shortVersion(version)).tag(String?.some(version))
            }
        }
        .aryaText(AryaFont.caption, AryaColor.inkMuted)
        .fixedSize()
    }

    private var pairKey: String {
        "\(old ?? item.defaultComparison?.old ?? "")>\(new ?? item.defaultComparison?.new ?? "")"
    }

    private func loadDiff() async {
        guard let from = old ?? item.defaultComparison?.old,
            let to = new ?? item.defaultComparison?.new
        else { return }
        diff = .loading
        diff = await RoutineDiffLoader.load(store.workspace, item: item, old: from, new: to)
    }
}
