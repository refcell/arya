import AryaDesign
import SwiftUI

/// The Changes tab: the outcome metric against its target, then the proposals. "Edit charter"
/// swaps the list for the charter editor, whose saves become proposals in this list.
struct ChangesTab: View {
    @ObservedObject var store: FeatureStore
    var steward: String
    @AryaState private var editing = false

    var body: some View {
        if editing {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button("Back to changes") { editing = false }.buttonStyle(.aryaTertiary)
                    Spacer()
                }
                .padding(.horizontal, AryaSpace.s5)
                .padding(.top, AryaSpace.s3)
                CharterEditorView(store: store, steward: steward)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: AryaSpace.s5) {
                    MetricChartView(store: store, steward: steward)
                        .frame(maxWidth: AryaSize.readingWidth, alignment: .leading)
                    Spacer()
                    Button("Edit charter") { editing = true }
                        .buttonStyle(.aryaSecondary)
                        .help("Changes are saved as a proposal, rehearsed, and gated.")
                }
                .padding(AryaSpace.s5)
                .aryaHairline(edge: .bottom)
                ChangesView(store: store, steward: steward)
            }
        }
    }
}
