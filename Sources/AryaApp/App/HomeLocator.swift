import Foundation

/// Where the app's workspace comes from.
enum HomeChoice: Equatable {
    /// A home directory on disk.
    case home(URL)
}

/// Resolves the home once at launch (ARCHITECTURE.md "Home directory"): `--home PATH`, then
/// `ARYA_HOME`, then
/// `~/Library/Application Support/arya`. Pure, so tests pass in their own inputs.
enum HomeLocator {
    static func resolve(
        arguments: [String], environment: [String: String], applicationSupport: URL
    ) -> HomeChoice {
        if let flag = arguments.firstIndex(of: "--home"), flag + 1 < arguments.count {
            return .home(
                URL(fileURLWithPath: (arguments[flag + 1] as NSString).expandingTildeInPath))
        }
        if let path = environment["ARYA_HOME"], !path.isEmpty {
            return .home(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        }
        return .home(applicationSupport.appendingPathComponent("arya", isDirectory: true))
    }
}
