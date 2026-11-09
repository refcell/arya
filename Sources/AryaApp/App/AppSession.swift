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

    /// Opens a home, replacing whatever was open.
    /// - Parameter environment: what adapter processes get (include `PATH`); the app passes
    ///   its own process environment.
    func open(_ choice: HomeChoice, environment: [String: String] = [:]) async {
        self.choice = choice
        problem = nil
        switch choice {
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
        model?.notifications = poster
    }

    /// Posts approval notifications when the app runs from its bundle.
    @ObservationIgnored private var poster: SystemNotificationPoster?

    /// Announces new approvals through the system, with Approve and Deny on each notice.
    func enableNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let poster =
            self.poster
            ?? SystemNotificationPoster { [weak self] approval, approved in
                guard let model = self?.model else { return }
                Task { approved ? await model.approve(approval) : await model.deny(approval) }
            }
        self.poster = poster
        model?.notifications = poster
    }

    /// The window subtitle: which home is open.
    var subtitle: String { model?.source.label ?? "" }
}
