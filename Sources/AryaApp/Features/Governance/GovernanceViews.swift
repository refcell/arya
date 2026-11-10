import AppKit
import Arya
import AryaDesign
import SwiftUI

// MARK: Run header: Abort and Undo

/// Abort (live runs, Command-period) and Undo (executed actions the charter can compensate) at
/// the right end of the run's header line.
struct RunGovernanceControls: View {
    @ObservedObject var store: FeatureStore
    var run: String
    @AryaState private var cache = GovernanceCache.shared
    @AryaState private var confirmAbort = false
    @AryaState private var showUndo = false
    @AryaState private var reason = ""

    var body: some View {
        let running = isRunning
        RunGovernanceBar(
            running: running, options: cache.undo[run] ?? [], problem: cache.problem,
            confirmAbort: $confirmAbort, showUndo: $showUndo, reason: $reason,
            abort: { text in
                guard let source = store.governance else { return }
                Task {
                    if await cache.abort(run: run, reason: text, from: source) {
                        reason = ""
                        await store.reload()
                    }
                }
            },
            undo: { option in
                guard let source = store.governance else { return }
                Task {
                    _ = await cache.undo(option, from: source)
                    await store.reload()
                }
            }
        )
        .task(id: "\(run)-\(eventCount)") {
            if let source = store.governance { await cache.load(run: run, from: source) }
        }
    }

    private var events: [FeatureEvent] {
        guard case .loaded(let events) = store.state else { return [] }
        return events
    }

    private var eventCount: Int { events.count }

    private var isRunning: Bool {
        if case .running = RunStream.build(events: events, run: run).status { return true }
        return false
    }
}

/// The controls themselves, with their state passed in, so snapshots draw them loaded.
struct RunGovernanceBar: View {
    var running: Bool
    var options: [UndoOption]
    var problem: String?
    @Binding var confirmAbort: Bool
    @Binding var showUndo: Bool
    @Binding var reason: String
    var abort: (String) -> Void
    var undo: (UndoOption) -> Void

    var body: some View {
        HStack(spacing: AryaSpace.s2) {
            if !options.isEmpty {
                Button {
                    showUndo.toggle()
                } label: {
                    HStack(spacing: AryaSpace.s1) {
                        Text("Undo").aryaText(AryaFont.caption, AryaColor.ink)
                        Text("\(options.filter { $0.undoneBy == nil }.count)")
                            .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                    }
                }
                .buttonStyle(.aryaQuiet)
                .help("Undo an executed action with its compensation; it goes through policy")
                .popover(isPresented: $showUndo, arrowEdge: .bottom) {
                    UndoList(options: options, undo: undo).padding(AryaSpace.s3)
                }
            }
            if running {
                Button {
                    confirmAbort = true
                } label: {
                    HStack(spacing: AryaSpace.s1) {
                        Text("■").aryaText(AryaFont.monoSmall, AryaColor.negative)
                        Text("Abort").aryaText(AryaFont.caption, AryaColor.negative)
                        Keycap("⌘.")
                    }
                    .foregroundStyle(AryaColor.negative)
                }
                .buttonStyle(.aryaQuiet)
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop this run now; nothing it proposed executes (Command-period)")
                .popover(isPresented: $confirmAbort, arrowEdge: .bottom) {
                    AbortConfirm(reason: $reason) {
                        confirmAbort = false
                        abort(reason)
                    } cancel: {
                        confirmAbort = false
                    }
                    .padding(AryaSpace.s3)
                }
            }
            if let problem {
                Text(problem).aryaText(AryaFont.caption, AryaColor.negative).lineLimit(1)
            }
        }
    }
}

/// The abort question: what happens, an optional reason, and the two answers.
struct AbortConfirm: View {
    @Binding var reason: String
    var confirm: () -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            Text("Abort this run?").aryaText(AryaFont.bodyStrong, AryaColor.ink)
            Text("It stops within a second. Nothing it proposed executes; the abort is recorded.")
                .aryaText(AryaFont.caption, AryaColor.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Reason (optional)", text: $reason)
                .textFieldStyle(.plain)
                .aryaText(AryaFont.mono, AryaColor.ink)
                .padding(AryaSpace.s1)
                .overlay(
                    RoundedRectangle(cornerRadius: AryaRadius.small)
                        .strokeBorder(AryaColor.rule, lineWidth: 1)
                )
                .onSubmit(confirm)
            HStack(spacing: AryaSpace.s2) {
                Spacer()
                Button("Keep running", action: cancel).buttonStyle(.aryaTertiary)
                    .keyboardShortcut(.cancelAction)
                Button(action: confirm) {
                    Text("Abort run").aryaText(AryaFont.caption, AryaColor.negative)
                }
                .buttonStyle(.aryaQuiet)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 300)
    }
}

/// Executed actions that can be undone: one mono line each, the compensation, and Undo.
struct UndoList: View {
    var options: [UndoOption]
    var undo: (UndoOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            Text("Undo an action").aryaText(AryaFont.label, AryaColor.inkFaint)
            ForEach(options, id: \.action) { option in
                HStack(spacing: AryaSpace.s2) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(GovernanceText.undoLine(option))
                            .aryaText(AryaFont.monoSmall, AryaColor.ink).lineLimit(1)
                        if let note = option.note {
                            Text(note).aryaText(AryaFont.caption, AryaColor.inkFaint)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: AryaSpace.s3)
                    if let by = option.undoneBy {
                        Chip("undone · \(by)", textColor: AryaColor.inkFaint)
                    } else {
                        Button("Undo") { undo(option) }.buttonStyle(.aryaSecondary)
                    }
                }
                .frame(minHeight: AryaSize.rowHeight)
            }
        }
        .frame(width: 360, alignment: .leading)
    }
}

// MARK: Inspector: policy, approvers, retention

/// The steward's policy in the inspector: autonomy, each binding's tool allowlist and action
/// kinds with decision, risk, and who approves, then its history retention.
struct StewardGovernanceSection: View {
    var model: AppModel
    var steward: String
    @AryaState private var cache = GovernanceCache.shared

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s3) {
            if let policy = cache.policies[steward] {
                PolicyPanel(
                    policy: policy, retentionDays: cache.retentionDays(steward: steward),
                    homeDays: cache.retention?.defaultDays
                ) { days in
                    guard let source = model.governance else { return }
                    Task { await cache.setRetention(steward: steward, days: days, from: source) }
                }
                AuditExportRow(last: cache.exports[steward]) {
                    guard let source = model.governance, let parent = Self.chooseFolder() else {
                        return
                    }
                    Task { await cache.export(steward: steward, into: parent, from: source) }
                }
            }
        }
        .task(id: "\(steward)-\(model.nextSeq)") {
            if let source = model.governance { await cache.load(steward: steward, from: source) }
        }
    }
}

extension StewardGovernanceSection {
    /// Asks where to put the export; nil when the person cancels.
    @MainActor static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export here"
        panel.message = "A new folder with the signed export is created inside the one you pick."
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// The audit export control and the last export's result.
struct AuditExportRow: View {
    var last: AuditExportSummary?
    var export: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            HStack {
                Text("Audit").aryaText(AryaFont.label, AryaColor.inkFaint)
                Spacer()
                Button("Export signed slice…", action: export).buttonStyle(.aryaQuiet)
                    .help(
                        "Write this steward's ledger lines and a manifest signed with the home's "
                            + "checkpoint key; anyone can check it without the home")
            }
            if let last {
                HStack(spacing: AryaSpace.s2) {
                    Chip(
                        last.verified ? "verified" : "check failed",
                        textColor: last.verified ? AryaColor.positive : AryaColor.negative,
                        borderColor: last.verified ? AryaColor.positive : AryaColor.negative)
                    Text(GovernanceText.exportLine(last))
                        .aryaText(AryaFont.monoSmall, AryaColor.inkMuted).lineLimit(1)
                }
                Text(URL(fileURLWithPath: last.directory).lastPathComponent)
                    .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                ForEach(last.issues, id: \.self) {
                    Text($0).aryaText(AryaFont.caption, AryaColor.negative)
                }
            }
        }
    }
}

/// The policy and retention content, with data passed in.
struct PolicyPanel: View {
    var policy: PolicySummary
    var retentionDays: Int?
    var homeDays: Int?
    var setRetention: (Int?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s3) {
            VStack(alignment: .leading, spacing: AryaSpace.s1) {
                label("Tools and actions")
                Text(GovernanceText.autonomyLine(policy))
                    .aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                ForEach(policy.bindings, id: \.id) { binding in
                    BindingPolicy(binding: binding)
                }
            }
            if !policy.approvers.isEmpty {
                VStack(alignment: .leading, spacing: AryaSpace.s1) {
                    label("Approvers")
                    ForEach(Array(policy.approvers.enumerated()), id: \.offset) { _, rule in
                        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                            Text(GovernanceText.ruleScope(rule))
                                .aryaText(AryaFont.monoSmall, AryaColor.ink)
                                .frame(width: 96, alignment: .leading)
                            Text(GovernanceText.people(rule.people))
                                .aryaText(AryaFont.caption, AryaColor.ink)
                        }
                        if let note = rule.note {
                            Text(note).aryaText(AryaFont.caption, AryaColor.inkFaint)
                                .padding(.leading, 104)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                label("Keep history")
                ChoiceRow(
                    GovernanceText.retentionChoices(home: homeDays), selection: retentionDays ?? 0
                ) { setRetention($0 == 0 ? nil : $0) }
                .help("Older closed ledger segments become eligible to archive; nothing is deleted")
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).aryaText(AryaFont.label, AryaColor.inkFaint)
    }
}

/// A policy decision chip: `ask` in neutral ink (orange stays for the one primary action),
/// `deny` in the negative tone, `auto` muted.
private struct DecisionChip: View {
    var decision: String

    var body: some View {
        Chip(
            decision,
            textColor: decision == "deny"
                ? AryaColor.negative : decision == "ask" ? AryaColor.ink : AryaColor.inkMuted,
            borderColor: decision == "deny" ? AryaColor.negative : AryaColor.rule
        )
        .accessibilityLabel("Policy \(decision)")
    }
}

/// One binding: id and kind, its tools, and a dense row per action kind.
private struct BindingPolicy: View {
    var binding: PolicySummary.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: AryaSpace.s2) {
                Text(binding.id).aryaText(AryaFont.monoStrong, AryaColor.ink)
                Text(binding.kind).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                if binding.network {
                    Text("net").aryaText(AryaFont.monoSmall, AryaColor.warning)
                }
                if let via = binding.via {
                    Text("via \(via)").aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                }
            }
            if !binding.tools.isEmpty {
                Text("reads " + binding.tools.joined(separator: " · "))
                    .aryaText(AryaFont.monoSmall, AryaColor.inkMuted).lineLimit(2)
            }
            ForEach(binding.actions, id: \.kind) { action in
                HStack(spacing: AryaSpace.s2) {
                    Text(action.kind).aryaText(AryaFont.monoSmall, AryaColor.ink)
                        .frame(width: 72, alignment: .leading)
                    DecisionChip(decision: action.decision)
                    Text(action.risk).aryaText(AryaFont.monoSmall, GovernanceText.riskColor(action))
                        .frame(width: 44, alignment: .leading)
                    Text(action.approvers.map(GovernanceText.people) ?? "anyone")
                        .aryaText(
                            AryaFont.caption,
                            action.approvers == nil ? AryaColor.inkFaint : AryaColor.ink
                        )
                        .lineLimit(1)
                }
                .frame(height: 20)
                .help(action.approverNote ?? action.reason)
            }
        }
        .padding(.leading, AryaSpace.s1)
    }
}

// MARK: Settings: retention and encryption

/// Home-level governance in app settings: default retention with what it covers now, and
/// encryption at rest.
struct HomeGovernanceSection: View {
    var source: (any GovernanceSource)?
    @AryaState private var cache = GovernanceCache.shared

    var body: some View {
        HomeGovernancePanel(
            retention: cache.retention, encryption: cache.encryption, problem: cache.problem,
            setDefault: { days in
                guard let source else { return }
                Task { await cache.setRetention(steward: nil, days: days, from: source) }
            },
            encrypt: {
                guard let source else { return }
                Task { await cache.enableEncryption(from: source) }
            }
        )
        .task { if let source { await cache.loadHome(from: source) } }
    }
}

/// The settings content, with data passed in.
struct HomeGovernancePanel: View {
    var retention: RetentionSummary?
    var encryption: EncryptionSummary?
    var problem: String?
    var setDefault: (Int?) -> Void
    var encrypt: () -> Void
    @AryaState private var confirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s3) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Keep history").aryaText(AryaFont.label, AryaColor.inkFaint)
                ChoiceRow(
                    GovernanceText.retentionChoices(home: nil),
                    selection: retention?.defaultDays ?? 0
                ) { setDefault($0 == 0 ? nil : $0) }
                if let retention {
                    Text(GovernanceText.planLine(retention))
                        .aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: AryaSpace.s1) {
                Text("Encryption at rest").aryaText(AryaFont.label, AryaColor.inkFaint)
                if let encryption, encryption.enabled {
                    HStack(spacing: AryaSpace.s2) {
                        Chip(
                            "on", textColor: AryaColor.positive, borderColor: AryaColor.positive)
                        Text(GovernanceText.keyLine(encryption))
                            .aryaText(AryaFont.monoSmall, AryaColor.ink)
                    }
                    Text(GovernanceText.coverageLine(encryption))
                        .aryaText(AryaFont.caption, AryaColor.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: AryaSpace.s2) {
                        Chip("off")
                        Text("Payloads, blobs, and caches are stored in the clear.")
                            .aryaText(AryaFont.caption, AryaColor.inkMuted)
                        Spacer()
                        Button("Encrypt…") { confirm = true }.buttonStyle(.aryaSecondary)
                            .disabled(encryption == nil)
                            .popover(isPresented: $confirm, arrowEdge: .bottom) {
                                encryptConfirm.padding(AryaSpace.s3)
                            }
                    }
                }
            }
            if let problem {
                Text(problem).aryaText(AryaFont.caption, AryaColor.negative)
            }
        }
    }

    private var encryptConfirm: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            Text("Encrypt this home?").aryaText(AryaFont.bodyStrong, AryaColor.ink)
            Text(GovernanceText.encryptWarning)
                .aryaText(AryaFont.caption, AryaColor.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { confirm = false }.buttonStyle(.aryaTertiary)
                    .keyboardShortcut(.cancelAction)
                Button("Encrypt") {
                    confirm = false
                    encrypt()
                }
                .buttonStyle(.aryaPrimary)
            }
        }
        .frame(width: 300)
    }
}

// MARK: Words

/// The governance views' sentences, kept apart so tests pin them.
enum GovernanceText {
    static let encryptWarning =
        "A new key goes into your Keychain. New events, blobs, and caches are sealed with it; "
        + "without the key this home cannot be read. Events already written stay as written."

    static func exportLine(_ summary: AuditExportSummary) -> String {
        let sealed = summary.sealed > 0 ? " · \(summary.sealed) sealed" : ""
        return "\(summary.count) events to seq \(summary.head)\(sealed) · \(summary.key)"
    }

    static func undoLine(_ option: UndoOption) -> String {
        let target = option.target.map { " \($0)" } ?? ""
        return "\(option.kind)\(target) → \(option.with)"
    }

    static func autonomyLine(_ policy: PolicySummary) -> String {
        let autonomy = policy.autonomy.map { "autonomy \($0) · " } ?? ""
        return "\(autonomy)Anything not listed: \(policy.fallback)"
    }

    /// Approver ids as names, people first and "you" (`local`) last: "Sam, you".
    static func people(_ ids: [String]) -> String {
        let named = ids.filter { $0 != "local" }.map(PeopleDirectory.displayName)
        guard ids.contains("local") else { return named.joined(separator: ", ") }
        return named.isEmpty ? "You" : (named + ["you"]).joined(separator: ", ")
    }

    static func ruleScope(_ rule: PolicySummary.ApproverLine) -> String {
        rule.binding.map { "\(rule.action)@\($0)" } ?? rule.action
    }

    static func riskColor(_ action: PolicySummary.Action) -> Color {
        switch action.risk {
        case "high": AryaColor.negative
        case "medium": AryaColor.warning
        default: AryaColor.inkMuted
        }
    }

    /// Retention choices; 0 means no own setting (the home default, or keep everything).
    static func retentionChoices(home: Int?) -> [(value: Int, title: String)] {
        let unset = home.map { "Home (\(days($0)))" } ?? "Forever"
        return [(0, unset), (30, "30 d"), (90, "90 d"), (365, "1 y")]
    }

    static func days(_ count: Int) -> String {
        count % 365 == 0 ? "\(count / 365) y" : "\(count) d"
    }

    static func planLine(_ retention: RetentionSummary) -> String {
        guard !retention.segments.isEmpty else { return "Nothing is old enough to archive." }
        let events = retention.events.values.reduce(0, +)
        let size = ByteCountFormatter.string(
            fromByteCount: Int64(retention.bytes), countStyle: .file)
        let head =
            "\(retention.segments.count) segments · \(events) events · \(size) eligible"
        return retention.blocker.map { "\(head). \($0)" } ?? head
    }

    static func keyLine(_ state: EncryptionSummary) -> String {
        let key = state.key ?? "?"
        let algorithm = state.algorithm ?? ""
        return state.keyAvailable ? "\(key) · \(algorithm)" : "\(key) · key not in Keychain"
    }

    static func coverageLine(_ state: EncryptionSummary) -> String {
        var parts = ["\(state.sealedBlobs) blobs sealed"]
        if state.clearBlobs > 0 { parts.append("\(state.clearBlobs) blobs in the clear") }
        if state.clearEvents > 0 {
            parts.append("\(state.clearEvents) earlier events stay as written")
        }
        return parts.joined(separator: " · ")
    }
}
