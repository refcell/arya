import Arya
import AryaDesign
import SwiftUI

/// One action in the command palette (Command-K): a title, a group, its shortcut, and what it
/// does. Lanes add theirs in `FeatureRegistry.commands(_:)`.
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let group: String
    /// The shortcut as shown in a keycap, "⌘1", "⌥⌘I"; nil when it has none.
    var keys: String?
    let perform: @MainActor (AppModel) -> Void
}

/// Every command the palette offers for the current state, shell commands first.
@MainActor
enum CommandCatalog {
    static func all(_ model: AppModel) -> [PaletteCommand] {
        shell(model) + FeatureRegistry.commands(model)
    }

    static func shell(_ model: AppModel) -> [PaletteCommand] {
        var out: [PaletteCommand] = []
        let steward = model.selectedSteward
        if let steward {
            if steward.status == .active {
                out.append(
                    PaletteCommand(
                        id: "run-now", title: "Run \(steward.name) now", group: "Steward",
                        keys: "⇧⌘R"
                    ) { model in Task { await model.startRun() } })
                out.append(
                    PaletteCommand(id: "pause", title: "Pause \(steward.name)", group: "Steward") {
                        model in Task { await model.setPaused(true) }
                    })
            } else if steward.status == .paused {
                out.append(
                    PaletteCommand(
                        id: "resume", title: "Resume \(steward.name)", group: "Steward"
                    ) { model in Task { await model.setPaused(false) } })
            }
            out.append(
                PaletteCommand(
                    id: "edit-charter", title: "Edit charter…", group: "Steward", keys: "⇧⌘E"
                ) { model in FeatureRegistry.editCharter(model) })
            out.append(
                PaletteCommand(
                    id: "rehearse", title: "Rehearse against past cases", group: "Steward"
                ) {
                    model in model.navigation.tab = .improve
                })
        }
        out.append(
            PaletteCommand(
                id: "new-steward", title: "New steward…", group: "Steward", keys: "⌘N"
            ) { model in model.stewardSheet = NewStewardDraft() })
        out.append(
            PaletteCommand(id: "needs-you", title: "Go to Needs you", group: "Go", keys: "⌘0") {
                model in model.navigation.showApprovals()
            })
        for (index, tab) in StewardTab.allCases.enumerated() where steward != nil {
            out.append(
                PaletteCommand(
                    id: "tab-\(tab.rawValue)", title: "Show \(tab.title)", group: "Go",
                    keys: "⌘\(index + 1)"
                ) { model in model.navigation.tab = tab })
        }
        for other in model.stewards {
            out.append(
                PaletteCommand(
                    id: "steward-\(other.id)", title: "Go to \(other.name)", group: "Stewards"
                ) {
                    model in model.navigation.select(steward: other.id)
                })
        }
        if let steward {
            for run in (model.runs[steward.id] ?? []).prefix(10) {
                out.append(
                    PaletteCommand(
                        id: "run-\(run.id)", title: StatusMapping.threadTitle(of: run),
                        group: "Runs"
                    ) { model in model.navigation.select(run: run.id, steward: steward.id) })
            }
        }
        for approval in model.approvals.prefix(10) {
            let what = [approval.actionKind, approval.target].compactMap { $0 }
                .joined(separator: " ")
            out.append(
                PaletteCommand(
                    id: "review-\(approval.id)", title: "Review \(what)", group: "Needs you"
                ) {
                    model in model.navigation.showApprovals()
                })
        }
        out.append(
            PaletteCommand(id: "sidebar", title: "Toggle sidebar", group: "View", keys: "⌘\\") {
                model in model.navigation.sidebar.toggle()
            })
        out.append(
            PaletteCommand(
                id: "inspector", title: "Toggle inspector", group: "View", keys: "⌥⌘I"
            ) { model in model.navigation.inspector.toggle() })
        out.append(
            PaletteCommand(id: "refresh", title: "Refresh", group: "View", keys: "⌘R") { model in
                Task { await model.refresh() }
            })
        return out
    }
}

/// Fuzzy matching for the palette: every query character in order, scored so whole-word and
/// prefix matches rank first.
enum PaletteSearch {
    /// Nil when `title` does not contain the query's characters in order; lower is better.
    static func score(_ title: String, query: String) -> Int? {
        let needle = query.lowercased().filter { !$0.isWhitespace }
        if needle.isEmpty { return 0 }
        let hay = Array(title.lowercased())
        var index = 0
        var score = 0
        var last = -1
        for character in needle {
            guard let found = hay[index...].firstIndex(of: character) else { return nil }
            let atWord = found == 0 || hay[found - 1] == " "
            score += (found - last - 1) * 2 - (atWord ? 3 : 0)
            last = found
            index = found + 1
        }
        if title.lowercased().hasPrefix(needle) { score -= 10 }
        return score
    }

    static func filter(_ commands: [PaletteCommand], query: String) -> [PaletteCommand] {
        var ranked: [(command: PaletteCommand, score: Int, order: Int)] = []
        for (order, command) in commands.enumerated() {
            if let score = score(command.title, query: query) {
                ranked.append((command, score, order))
            }
        }
        ranked.sort { lhs, rhs in
            lhs.score != rhs.score ? lhs.score < rhs.score : lhs.order < rhs.order
        }
        return ranked.map(\.command)
    }
}

/// The command palette: a search line, then matching commands with their groups and keycaps.
/// ↑/↓ move, ↩ runs, Esc closes.
struct CommandPaletteView: View {
    let model: AppModel
    @AryaState private var query = ""
    @AryaState private var highlighted = 0
    @FocusState private var focused: Bool

    var body: some View {
        let matches = Array(
            PaletteSearch.filter(CommandCatalog.all(model), query: query).prefix(12))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AryaSpace.s2) {
                Text("›").aryaText(AryaFont.mono, AryaColor.inkFaint)
                TextField("Type a command or a steward", text: $query)
                    .textFieldStyle(.plain)
                    .aryaText(AryaFont.body, AryaColor.ink)
                    .focused($focused)
                    .onSubmit { run(matches) }
                Keycap("esc")
            }
            .padding(.horizontal, AryaSpace.s3)
            .frame(height: AryaSize.controlHeight + AryaSpace.s2)
            AryaHairline()
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(matches.enumerated()), id: \.element.id) { index, command in
                    Button {
                        command.perform(model)
                        model.paletteOpen = false
                    } label: {
                        HStack(spacing: AryaSpace.s2) {
                            Text(command.title).aryaText(AryaFont.body, AryaColor.ink).lineLimit(1)
                            Spacer(minLength: AryaSpace.s2)
                            Text(command.group).aryaText(AryaFont.caption, AryaColor.inkFaint)
                            if let keys = command.keys { Keycap(keys) }
                        }
                        .padding(.horizontal, AryaSpace.s3)
                        .frame(height: AryaSize.rowHeight)
                        .background(index == highlighted ? AryaColor.selection : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if matches.isEmpty {
                    Text("No command matches").aryaText(AryaFont.caption, AryaColor.inkFaint)
                        .padding(AryaSpace.s3)
                }
            }
            .padding(.vertical, AryaSpace.s1)
        }
        .frame(width: AryaSize.paletteWidth)
        .background(AryaColor.raised, in: RoundedRectangle(cornerRadius: AryaRadius.small))
        .overlay(
            RoundedRectangle(cornerRadius: AryaRadius.small).strokeBorder(AryaColor.ruleStrong)
        )
        .onAppear { focused = true }
        .onChange(of: query) { highlighted = 0 }
        .onKeyPress(.downArrow) {
            highlighted = min(highlighted + 1, max(matches.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max(highlighted - 1, 0)
            return .handled
        }
        .onKeyPress(.escape) {
            model.paletteOpen = false
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette")
    }

    private func run(_ matches: [PaletteCommand]) {
        guard matches.indices.contains(highlighted) else { return }
        matches[highlighted].perform(model)
        model.paletteOpen = false
    }
}
