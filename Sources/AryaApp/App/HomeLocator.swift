import Foundation

/// Where the app's workspace comes from.
enum HomeChoice: Equatable {
    /// A home directory on disk.
    case home(URL)
    /// The in-memory preview workspace with sample stewards.
    case preview
}

/// Resolves the home once at launch (ARCHITECTURE.md "Home directory"): `--preview` or
/// `ARYA_PREVIEW=1` picks sample data, then `ARYA_HOME`, then
/// `~/Library/Application Support/arya`. Pure, so tests pass in their own inputs.
enum HomeLocator {
    static func resolve(
        arguments: [String], environment: [String: String], applicationSupport: URL
    ) -> HomeChoice {
        if arguments.contains("--preview") || environment["ARYA_PREVIEW"] == "1" {
            return .preview
        }
        if let path = environment["ARYA_HOME"], !path.isEmpty {
            return .home(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        }
        return .home(applicationSupport.appendingPathComponent("arya", isDirectory: true))
    }
}
