import Arya
import AryaDesign
import SwiftUI

// app-shell (Templates, #16): step 0 of New steward. Picking a template prefills every step;
// the person still walks the steps and creates through `createSteward` as usual.

extension NewStewardDraft {
    /// The steps prefilled from a template's draft.
    static func template(_ source: StewardDraft) -> NewStewardDraft {
        var draft = NewStewardDraft()
        draft.name = source.name
        draft.outcome = source.outcome
        draft.metric = source.metric
        draft.unit = source.unit
        draft.direction = source.direction
        draft.target = source.target.map { number($0) } ?? ""
        draft.guardrails = source.guardrails.joined(separator: "\n")
        draft.autonomy = source.autonomy == "auto" ? .auto : .ask
        draft.level = source.level
        draft.department = source.department ?? ""
        draft.effort = source.effort
        draft.people = []
        for (index, binding) in source.bindings.enumerated() {
            if binding.kind == "person" {
                let name =
                    binding.id.hasPrefix("person:") ? String(binding.id.dropFirst(7)) : binding.id
                let channel = binding.channel ?? "inbox"
                draft.people.append(Person(id: index, name: name, channel: channel))
                if !draft.channels.contains(channel) { draft.channels.append(channel) }
            } else if let command = binding.command {
                draft.connections.append(
                    Connection(
                        id: binding.id, command: command, args: binding.args, read: binding.read,
                        actions: binding.actions, isOn: true))
            }
        }
        if draft.people.isEmpty { draft.people = [Person(id: 0)] }
        var asks = Set<String>()
        var ruled = Set<String>()
        for rule in source.rules {
            ruled.insert(rule.action)
            switch rule.decision {
            case "deny": draft.never.insert(rule.action)
            case "ask": asks.insert(rule.action)
            default: break
            }
        }
        let unruled = draft.actionKinds.filter { !ruled.contains($0) }
        draft.signOff = asks.union(draft.autonomy == .ask ? unruled : [])
        let interval = source.triggers.first { $0.kind == "interval" }?.everySeconds
        draft.everyMinutes = interval.map { String($0 / 60) } ?? ""
        draft.wakesOnMessage = source.triggers.contains { $0.kind == "message" }
        return draft
    }
}

/// One template as a dense row reads it.
struct TemplateRow: Equatable, Identifiable {
    var id: String
    var name: String
    var department: String
    var summary: String
    /// "routed within 1h ≥ 0.95", "cost per lead ≤ 40 usd".
    var metric: String
    /// "ask · 2 auto", "Acts alone on low risk".
    var policy: String

    static func build(_ template: StewardTemplate) -> TemplateRow {
        build(
            id: template.id, name: template.name, department: template.department,
            summary: template.summary, draft: template.draft)
    }

    static func build(
        id: String, name: String, department: String, summary: String, draft: StewardDraft
    ) -> TemplateRow {
        let sign = draft.direction == "down" ? "≤" : "≥"
        let target = draft.target.map { " \(sign) \(StatusMapping.metric($0))" } ?? ""
        let automatic = draft.rules.filter { $0.decision == "auto" }.count
        // In words, never the key: "Acts alone on low risk", "routed within 1h ≥ 0.95".
        var policy = [draft.level.map(ActionWords.autonomy) ?? draft.autonomy]
        if automatic > 0 { policy.append("\(automatic) auto") }
        return TemplateRow(
            id: id, name: name, department: department, summary: summary,
            metric: MetricText.name(draft.metric) + target,
            policy: policy.joined(separator: " · "))
    }
}

/// Step 0: start blank or from a template, as dense rows (name, department, outcome, metric,
/// default policy). j/k move, Return picks.
struct NewStewardTemplatePicker: View {
    let templates: [StewardTemplate]
    let choose: (StewardTemplate?) -> Void
    @AryaState private var selected = 0
    private static let departmentWidth: CGFloat = 96
    private static let metricWidth: CGFloat = 232
    private static let policyWidth: CGFloat = 128
    @FocusState private var focused: Bool

    private var rows: [TemplateRow] { templates.map(TemplateRow.build) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            row(
                index: 0, title: "Blank", department: "",
                summary: "Answer each step yourself.", metric: "", policy: "")
            ForEach(Array(rows.enumerated()), id: \.element.id) { offset, item in
                row(
                    index: offset + 1, title: item.name, department: item.department,
                    summary: item.summary, metric: item.metric, policy: item.policy)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(characters: CharacterSet(charactersIn: "jk")) { press in
            let delta = press.characters == "j" ? 1 : -1
            selected = min(max(selected + delta, 0), templates.count)
            return .handled
        }
        .onKeyPress(.return) {
            choose(selected == 0 ? nil : templates[selected - 1])
            return .handled
        }
    }

    private var header: some View {
        HStack(spacing: AryaSpace.s2) {
            label("Template", width: nil)
            label("Department", width: Self.departmentWidth)
            label("Metric", width: Self.metricWidth)
            label("Policy", width: Self.policyWidth)
        }
        .frame(height: AryaSize.rowHeight)
        .aryaHairline(edge: .bottom)
    }

    private func label(_ text: String, width: CGFloat?) -> some View {
        Text(text).aryaText(AryaFont.label, AryaColor.inkFaint)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    private func row(
        index: Int, title: String, department: String, summary: String, metric: String,
        policy: String
    ) -> some View {
        let isSelected = index == selected
        return Button {
            selected = index
            choose(index == 0 ? nil : templates[index - 1])
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).aryaText(AryaFont.bodyStrong, AryaColor.ink)
                    Text(summary).aryaText(AryaFont.caption, AryaColor.inkMuted).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(department).aryaText(AryaFont.caption, AryaColor.inkMuted)
                    .frame(width: Self.departmentWidth, alignment: .leading)
                Text(MetricText.name(metric)).aryaText(AryaFont.monoSmall, AryaColor.ink)
                    .lineLimit(1)
                    .frame(width: Self.metricWidth, alignment: .leading)
                Text(policy).aryaText(AryaFont.monoSmall, AryaColor.inkMuted).lineLimit(1)
                    .frame(width: Self.policyWidth, alignment: .leading)
            }
            .padding(.vertical, AryaSpace.s1)
            .padding(.horizontal, AryaSpace.s2)
            .background(
                isSelected ? AryaColor.selection : .clear,
                in: RoundedRectangle(cornerRadius: AryaRadius.small)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(index == 0 ? "Start blank" : "Start from \(title)")
    }
}
