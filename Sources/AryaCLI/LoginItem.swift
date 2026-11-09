import Foundation

/// `arya serve` as a login item: a per-user LaunchAgent that starts `arya --home <home> serve`
/// at login and restarts it if it exits with an error. A plain command-line binary has no app
/// bundle to register, so it uses a LaunchAgent plist and `launchctl` instead.
struct LaunchAgent: Sendable, Equatable {
    static let label = "app.arya.serve"

    /// The `arya` executable to run.
    let binary: String
    /// The home it serves.
    let home: String
    /// Seconds between scheduler ticks.
    let every: Int

    var programArguments: [String] {
        [binary, "--home", home, "serve", "--every", String(every)]
    }

    /// Where the agent writes its output.
    var logPath: String {
        URL(fileURLWithPath: home).appendingPathComponent("logs/serve.log").path
    }

    /// The plist launchd reads.
    func plist() throws(CLIError) -> Data {
        let dictionary: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": programArguments,
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Background",
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
        do {
            return try PropertyListSerialization.data(
                fromPropertyList: dictionary, format: .xml, options: 0)
        } catch {
            throw .failed("could not write the login item: \(error)")
        }
    }
}

/// Installs and removes the LaunchAgent. `agents` is `~/Library/LaunchAgents` in the CLI and a
/// temporary directory in tests; `launchctl` runs `/bin/launchctl` in the CLI and a fake in
/// tests, and returns its exit status.
struct LoginItems: Sendable {
    let agents: URL
    let domain: String
    let launchctl: @Sendable ([String]) -> Int32

    var plistURL: URL { agents.appendingPathComponent("\(LaunchAgent.label).plist") }

    /// The CLI's: the user's LaunchAgents directory and the GUI launchd domain.
    static func user() -> LoginItems {
        let agents = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        return LoginItems(agents: agents, domain: "gui/\(getuid())") { arguments in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return -1
            }
            process.waitUntilExit()
            return process.terminationStatus
        }
    }

    /// Writes the agent's plist, replaces any loaded copy, and loads it.
    func install(_ agent: LaunchAgent) throws(CLIError) -> LoginItemReport {
        let data = try agent.plist()
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: agents, withIntermediateDirectories: true)
            let logs = URL(fileURLWithPath: agent.logPath).deletingLastPathComponent()
            try fm.createDirectory(at: logs, withIntermediateDirectories: true)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            throw .failed("could not write \(plistURL.path): \(error.localizedDescription)")
        }
        _ = launchctl(["bootout", "\(domain)/\(LaunchAgent.label)"])
        let status = launchctl(["bootstrap", domain, plistURL.path])
        guard status == 0 else {
            throw .failed(
                "launchctl bootstrap failed (\(status)); the plist is at \(plistURL.path)")
        }
        return LoginItemReport(
            label: LaunchAgent.label, state: .installed, plist: plistURL.path,
            program: agent.programArguments, log: agent.logPath)
    }

    /// Unloads the agent and removes its plist; succeeds when it was not installed.
    func uninstall() throws(CLIError) -> LoginItemReport {
        _ = launchctl(["bootout", "\(domain)/\(LaunchAgent.label)"])
        let fm = FileManager.default
        if fm.fileExists(atPath: plistURL.path) {
            do {
                try fm.removeItem(at: plistURL)
            } catch {
                throw .failed("could not remove \(plistURL.path): \(error.localizedDescription)")
            }
        }
        return LoginItemReport(
            label: LaunchAgent.label, state: .removed, plist: plistURL.path, program: nil,
            log: nil)
    }
}

/// The result of `arya serve install` and `arya serve uninstall`.
struct LoginItemReport: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable { case installed, removed }

    let label: String
    let state: State
    let plist: String
    let program: [String]?
    let log: String?

    enum CodingKeys: String, CodingKey { case label, state, plist, program, log }
}
