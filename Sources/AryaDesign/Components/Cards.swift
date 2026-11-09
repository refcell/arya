import SwiftUI

/// The one place the interface asks for a person: `accentWash` fill, medium radius, 16 pt
/// padding, a 2 pt `accent` left edge, and Deny then Approve right-aligned.
public struct ApprovalCard: View {
    let action: String
    let summary: String
    let rationale: String
    let context: String
    let approveLabel: String
    let onDeny: () -> Void
    let onApprove: () -> Void
    @FocusState private var isFocused: Bool

    /// What a key does to a focused card: Command-Return approves and Command-Delete denies
    /// (decision 0034). Without Command nothing happens, so a stray Return never grants.
    public enum KeyAction: Equatable, Sendable { case approve, deny }

    public static func action(for key: KeyEquivalent, modifiers: EventModifiers) -> KeyAction? {
        guard modifiers.contains(.command) else { return nil }
        switch key {
        case .return: return .approve
        case .delete: return .deny
        default: return nil
        }
    }

    /// - Parameters:
    ///   - action: kind and target, in `mono` (`close_issue #418`).
    ///   - context: steward, run, and time (`Triage keeper · run 14 · 2m ago`).
    ///   - approveLabel: names the effect ("Approve and run", "Ship").
    public init(
        action: String, summary: String, rationale: String, context: String,
        approveLabel: String = "Approve and run", onDeny: @escaping () -> Void,
        onApprove: @escaping () -> Void
    ) {
        self.action = action
        self.summary = summary
        self.rationale = rationale
        self.context = context
        self.approveLabel = approveLabel
        self.onDeny = onDeny
        self.onApprove = onApprove
    }

    public var body: some View {
        // Unboxed (STYLE.md Approval block): structure from type and spacing, no fill or frame.
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            Text("Needs your approval").aryaText(AryaFont.label, AryaColor.accent)
            Text(action).aryaText(AryaFont.monoStrong, AryaColor.ink)
            Text(summary).aryaText(AryaFont.body, AryaColor.ink)
            if !rationale.isEmpty {
                Text(rationale).aryaText(AryaFont.body, AryaColor.inkMuted)
            }
            Text(context).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
            HStack(spacing: AryaSpace.s2) {
                Button("Deny", action: onDeny).buttonStyle(.aryaQuiet)
                    .accessibilityLabel("Deny \(action)")
                Button(approveLabel, action: onApprove).buttonStyle(.aryaPrimary)
                    .accessibilityLabel("\(approveLabel): \(action)")
            }
            .padding(.top, AryaSpace.s1)
        }
        .padding(.vertical, AryaSpace.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AryaSize.focusRing * 2)
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: AryaRadius.medium + AryaSize.focusRing * 2)
                    .strokeBorder(AryaColor.accent, lineWidth: AryaSize.focusRing)
            }
        }
        .padding(-AryaSize.focusRing * 2)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.return, .delete]) { press in
            switch Self.action(for: press.key, modifiers: press.modifiers) {
            case .approve: onApprove()
            case .deny: onDeny()
            case nil: return .ignored
            }
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Approve", onApprove)
        .accessibilityAction(named: "Deny", onDeny)
    }
}

/// Centered in the reading width, 48 pt from the top: one `display` sentence, one line of
/// guidance, and at most one secondary button.
public struct EmptyState: View {
    let title: String
    let guidance: String
    let actionTitle: String?
    let action: (() -> Void)?

    public init(
        _ title: String, guidance: String, actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.guidance = guidance
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            Text(title).aryaText(AryaFont.body, AryaColor.inkMuted)
            Text(guidance).aryaText(AryaFont.caption, AryaColor.inkFaint)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.aryaSecondary)
                    .padding(.top, AryaSpace.s2)
            }
        }
        .frame(maxWidth: AryaSize.readingWidth, alignment: .leading)
        .padding(AryaSpace.s5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
