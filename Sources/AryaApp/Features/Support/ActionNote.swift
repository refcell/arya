import AryaDesign
import SwiftUI

/// The muted lines under a manual action (Run now, Rehearse): that a paused steward's
/// scheduled runs are off, and the workspace's refusal, if the last write failed.
struct ActionNote: View {
    @ObservedObject var store: FeatureStore
    var paused: Bool

    var body: some View {
        if paused {
            Text(ActionNote.pausedText).aryaText(AryaFont.caption, AryaColor.inkMuted)
        }
        if let error = store.writeError {
            Text(error).aryaText(AryaFont.caption, AryaColor.negative)
        }
    }

    static let pausedText = "Paused: scheduled runs are off."
}
