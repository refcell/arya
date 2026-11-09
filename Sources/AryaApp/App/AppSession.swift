import Arya
import Foundation
import Observation

/// Owns the open workspace for the window, and reopens it when the person picks another home.
@MainActor @Observable
final class AppSession {
    private(set) var model: AppModel?
    private(set) var choice: HomeChoice?
    /// Why the home could not be opened, phrased for people.
    private(set) var problem: String?

    /// Opens a home or the preview workspace, replacing whatever was open.
    /// - Parameter environment: what adapter processes get (include `PATH`); the app passes
    ///   its own process environment.
    func open(_ choice: HomeChoice, environment: [String: String] = [:]) async {
        self.choice = choice
        problem = nil
        switch choice {
        case .preview:
            let now = ShellPreviewWorkspace.referenceDate
            model = AppModel(
                source: ShellPreviewWorkspace(now: now),
                featureStore: FeatureStore(workspace: PreviewWorkspace.triage(now: now), now: now))
        case .home(let url):
            do {
                let workspace = try await Workspace.open(home: url, environment: environment)
                model = AppModel(
                    source: workspace,
                    featureStore: FeatureStore(workspace: FacadeFeatureWorkspace(source: workspace))
                )
            } catch {
                model = nil
                problem = "Could not open the home at \(url.lastPathComponent): \(error)."
            }
        }
    }

    /// The window subtitle: which home is open.
    var subtitle: String { model?.source.label ?? "" }
}
