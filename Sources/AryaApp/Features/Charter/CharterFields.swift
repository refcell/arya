import AryaDesign
import SwiftUI

/// The editable sections of a charter draft.
struct CharterFields: View {
    @Binding var draft: CharterDraft

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s6) {
            section("Outcome") {
                CharterTextField(placeholder: "What the steward owns", text: $draft.outcome)
            }
            section("Metric") { metric }
            section("Guardrails") { guardrails }
            section("Bindings") { bindings }
            section("Triggers") { triggers }
            section("Policy") { policy }
            section("Effort") {
                EffortSelector(
                    selection: Binding(
                        get: { AryaEffort(rawValue: draft.effort) ?? .medium },
                        set: { draft.effort = $0.rawValue }))
            }
        }
    }

    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AryaSpace.s3) {
            Text(title).aryaText(AryaFont.heading, AryaColor.ink)
            content()
        }
    }

    private var metric: some View {
        HStack(alignment: .bottom, spacing: AryaSpace.s3) {
            labeled("Name") {
                CharterTextField(placeholder: "name", text: $draft.metricName, mono: true)
            }
            labeled("Unit") { CharterTextField(placeholder: "unit", text: $draft.metricUnit) }
            labeled("Better when") {
                Picker("Better when", selection: $draft.metricDirection) {
                    Text("higher").tag("up")
                    Text("lower").tag("down")
                }
                .labelsHidden().fixedSize()
            }
            labeled("Target") {
                CharterTextField(placeholder: "none", text: $draft.metricTarget, mono: true)
            }
        }
    }

    private var guardrails: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            ForEach(draft.guardrails.indices, id: \.self) { index in
                HStack(spacing: AryaSpace.s2) {
                    CharterTextField(
                        placeholder: "A rule the steward never breaks",
                        text: $draft.guardrails[index])
                    Button("Remove") { draft.guardrails.remove(at: index) }.buttonStyle(
                        .aryaTertiary)
                }
            }
            Button("Add guardrail") { draft.guardrails.append("") }.buttonStyle(.aryaTertiary)
        }
    }

    private var bindings: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s4) {
            ForEach($draft.bindings, id: \.key) { $binding in
                VStack(alignment: .leading, spacing: AryaSpace.s2) {
                    HStack(spacing: AryaSpace.s2) {
                        CharterTextField(placeholder: "id", text: $binding.id, mono: true)
                        Picker("Kind", selection: $binding.kind) {
                            ForEach(CharterDraft.bindingKinds, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        Button("Remove") { draft.bindings.removeAll { $0.key == binding.key } }
                            .buttonStyle(.aryaTertiary)
                    }
                    if binding.kind == "person" {
                        labeled("Channel") {
                            CharterTextField(placeholder: "inbox", text: $binding.channel)
                        }
                    } else {
                        labeled("Command") {
                            CharterTextField(
                                placeholder: "server command", text: $binding.command, mono: true)
                        }
                        labeled("Read tools, comma-separated") {
                            CharterTextField(
                                placeholder: "search, get", text: $binding.read, mono: true)
                        }
                        labeled("Actions, comma-separated") {
                            CharterTextField(
                                placeholder: "label, comment", text: $binding.actions, mono: true)
                        }
                    }
                }
                AryaHairline()
            }
            Button("Add binding") { draft.addBinding() }.buttonStyle(.aryaTertiary)
        }
    }

    private var triggers: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            ForEach($draft.triggers) { $trigger in
                HStack(spacing: AryaSpace.s2) {
                    Picker("Kind", selection: $trigger.kind) {
                        ForEach(CharterDraft.triggerKinds, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    if trigger.kind == "interval" {
                        Stepper(value: $trigger.everySeconds, in: 60...86_400, step: 60) {
                            Text("every \(trigger.everySeconds / 60) min")
                                .aryaText(AryaFont.body, AryaColor.ink).monospacedDigit()
                        }
                    }
                    Spacer()
                    Button("Remove") { draft.triggers.removeAll { $0.key == trigger.key } }
                        .buttonStyle(.aryaTertiary)
                }
            }
            Button("Add trigger") { draft.addTrigger() }.buttonStyle(.aryaTertiary)
        }
    }

    private var policy: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            HStack(spacing: AryaSpace.s2) {
                Text("Unlisted actions").aryaText(AryaFont.body, AryaColor.inkMuted)
                decisionPicker($draft.policyDefault)
            }
            ForEach($draft.policyRules) { $rule in
                HStack(spacing: AryaSpace.s2) {
                    CharterTextField(placeholder: "action", text: $rule.action, mono: true)
                    decisionPicker($rule.decision)
                    Button("Remove") { draft.policyRules.removeAll { $0.key == rule.key } }
                        .buttonStyle(.aryaTertiary)
                }
            }
            Button("Add rule") { draft.addRule() }.buttonStyle(.aryaTertiary)
        }
    }

    private func decisionPicker(_ selection: Binding<String>) -> some View {
        Picker("Decision", selection: selection) {
            ForEach(CharterDraft.decisions, id: \.self) { Text($0).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
    }
}
