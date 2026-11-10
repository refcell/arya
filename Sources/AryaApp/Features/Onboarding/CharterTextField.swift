import AryaDesign
import SwiftUI

/// A plain text field on the `sunken` fill.
struct CharterTextField: View {
    var placeholder: String
    @Binding var text: String
    var mono = false

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .aryaText(mono ? AryaFont.mono : AryaFont.body, AryaColor.ink)
            .padding(AryaSpace.s2)
            .background(AryaColor.sunken, in: RoundedRectangle(cornerRadius: AryaRadius.small))
    }
}

/// A caption label above its control.
@MainActor
func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: AryaSpace.s1) {
        Text(title).aryaText(AryaFont.caption, AryaColor.inkMuted)
        content()
    }
}
