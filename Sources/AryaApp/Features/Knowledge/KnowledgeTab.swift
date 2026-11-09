import AryaDesign
import SwiftUI

/// What a steward knows, in one column (STYLE.md Knowledge): memory notes as a quiet sentence
/// with one muted provenance line, then routines as rows that expand to their version history.
/// No nested panes, chips, or ids; Retract is on hover and in the context menu.
struct KnowledgeTab: View {
    @ObservedObject var store: FeatureStore
    var steward: String
    @AryaState private var failure: String?
    @AryaState private var expanded: Set<String> = []

    var body: some View {
        Group {
            if let knowledge = store.knowledge[steward] {
                content(knowledge)
            } else if let failure {
                EmptyState(
                    "Knowledge could not be loaded.", guidance: failure, actionTitle: "Retry",
                    action: { Task { await load() } })
            } else {
                EmptyState("Loading knowledge.", guidance: "Reading notes and routines.")
            }
        }
        .task(id: "\(steward)#\(revision)") { await load() }
    }

    /// Changes whenever the ledger grows, so a retract or a new note reloads the screen.
    private var revision: Int {
        if case .loaded(let events) = store.state { return events.count }
        return 0
    }

    private func load() async {
        do {
            store.knowledge[steward] = try await store.workspace.knowledge(steward: steward)
            failure = nil
        } catch FeatureReadError.unavailable {
            failure = "This home cannot list knowledge yet."
        } catch {
            failure = "The notes and routines could not be read."
        }
    }

    private func content(_ knowledge: FeatureKnowledge) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                FeatureWriteErrorLine(store: store)
                section("Memory", count: knowledge.notes.count)
                if knowledge.notes.isEmpty {
                    quiet("No notes yet. Runs and your corrections add them.")
                }
                ForEach(knowledge.notes) { note in
                    NoteRow(note: note) {
                        Task { await store.perform(.retractMemory(note: note.id, reason: "")) }
                    }
                }
                section("Routines", count: knowledge.routines.count)
                    .padding(.top, AryaSpace.s6)
                if knowledge.routines.isEmpty {
                    quiet("No routines yet. When a steward repeats work, it proposes one.")
                }
                ForEach(knowledge.routines) { routine in
                    RoutineRow(routine: routine, isExpanded: expanded.contains(routine.id)) {
                        if expanded.contains(routine.id) {
                            expanded.remove(routine.id)
                        } else {
                            expanded.insert(routine.id)
                        }
                    }
                }
            }
            .frame(maxWidth: AryaSize.readingWidth, alignment: .leading)
            .padding(.horizontal, AryaSize.pagePadding)
            .padding(.vertical, AryaSpace.s5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section(_ title: String, count: Int) -> some View {
        HStack(spacing: AryaSpace.s2) {
            Text(title).aryaText(AryaFont.label, AryaColor.inkFaint)
            if count > 0 { Text("\(count)").aryaText(AryaFont.monoSmall, AryaColor.inkFaint) }
        }
        .padding(.bottom, AryaSpace.s2)
    }

    private func quiet(_ text: String) -> some View {
        Text(text).aryaText(AryaFont.caption, AryaColor.inkFaint).padding(.vertical, AryaSpace.s2)
    }
}

/// One memory note: the sentence, then where it came from and when.
private struct NoteRow: View {
    var note: FeatureKnowledge.Note
    var retract: () -> Void
    @AryaState private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s3) {
            VStack(alignment: .leading, spacing: AryaSpace.s1) {
                Text(note.text).aryaText(AryaFont.body, AryaColor.ink)
                Text(KnowledgeText.provenance(note))
                    .aryaText(AryaFont.caption, AryaColor.inkFaint)
                    .help(note.absoluteTime)
            }
            Spacer(minLength: AryaSpace.s3)
            Button("Retract", action: retract)
                .buttonStyle(.aryaTertiary)
                .opacity(hovering ? 1 : 0)
                .help("Hide this note from future runs. The ledger keeps it.")
                .accessibilityLabel("Retract note")
        }
        .padding(.vertical, AryaSpace.s2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Retract", action: retract)
            Button("Copy Note ID") { copy(note.id) }
            if let run = note.run { Button("Copy Run ID") { copy(run) } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Retract", retract)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A routine: its name in mono and one status word; expanded, every version newest first.
private struct RoutineRow: View {
    var routine: FeatureKnowledge.Routine
    var isExpanded: Bool
    var toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                    DisclosureChevron(isExpanded: isExpanded)
                    Text(routine.name).aryaText(AryaFont.mono, AryaColor.ink)
                    Text(routine.status)
                        .aryaText(
                            AryaFont.caption,
                            routine.status == "waiting" ? AryaColor.accent : AryaColor.inkMuted)
                    Text(routine.summary)
                        .aryaText(AryaFont.caption, AryaColor.inkFaint)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, AryaSpace.s2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Routine \(routine.name), \(routine.status)")
            .accessibilityAddTraits(isExpanded ? .isSelected : [])
            if isExpanded {
                ForEach(routine.versions, id: \.version) { version in
                    HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s3) {
                        Text(KnowledgeText.shortVersion(version.version))
                            .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                            .help(version.version)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(version.summary.isEmpty ? "No summary." : version.summary)
                                .aryaText(AryaFont.body, AryaColor.inkMuted)
                            Text("\(version.approval) · \(version.time)")
                                .aryaText(AryaFont.caption, AryaColor.inkFaint)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, AryaSpace.s5)
                    .padding(.vertical, AryaSpace.s1)
                }
            }
        }
    }
}
