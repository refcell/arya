import Arya
import AryaDesign
import SwiftUI

/// The top-level window content. Placeholder until the shell lane fills it in.
struct RootView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("arya")
                .font(.system(size: 48, weight: .regular, design: .serif))
            FeaturePlaceholder()
        }
        .frame(minWidth: 480, minHeight: 320)
        .padding(32)
    }
}
