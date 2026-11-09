import Arya
import SwiftUI

/// What a feature view gets from the shell: the app model and the current selection.
///
/// Contract for `Sources/AryaApp/Features`: a feature view takes a `FeatureContext`, reads
/// state from `model`, writes only through `model` (which records ledger events through the
/// facade), and uses `AryaDesign` tokens and components only.
struct FeatureContext {
    let model: AppModel
    /// The selected steward, for steward tabs.
    let steward: StewardSummary?
    /// The run selected in the rail, if any.
    let run: RunSummary?
    /// The event store the feature views observe (`Features/Support`), when one is wired.
    let store: FeatureStore?
    /// The steward's runs, newest first, for views that default to the latest run.
    let runs: [RunSummary]
}
