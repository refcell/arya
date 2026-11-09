import AryaAdapters
import AryaCore
import AryaRuntime
import Foundation

/// `adapters.json` in the home: named adapter profiles, each a command and its arguments per
/// effort (PROTOCOL.md "Effort"). A charter names a profile in `adapter`.
struct AdapterProfiles: Sendable, Hashable, Codable {
    struct Profile: Sendable, Hashable, Codable {
        var command: String
        var args: [String: [String]]

        init(command: String, args: [String: [String]] = [:]) {
            self.command = command
            self.args = args
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            command = try c.decode(String.self, forKey: .command)
            args = try c.decodeIfPresent([String: [String]].self, forKey: .args) ?? [:]
        }

        enum CodingKeys: String, CodingKey { case command, args }
    }

    var v: Int
    var profiles: [String: Profile]

    init(profiles: [String: Profile] = [:]) {
        v = 1
        self.profiles = profiles
    }

    /// The profiles in `home/adapters.json`; none when the file is missing.
    static func load(home: URL) throws -> AdapterProfiles {
        let url = home.appendingPathComponent("adapters.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return AdapterProfiles() }
        do {
            return try JSONDecoder().decode(AdapterProfiles.self, from: Data(contentsOf: url))
        } catch {
            throw WorkspaceError.rejected("adapters.json: \(error)")
        }
    }
}

/// Launches one adapter process per run from the home's profiles. The profile file is read at
/// each run, so editing `adapters.json` needs no restart.
struct ProfileAdapterFactory: AdapterFactory {
    let home: URL
    /// The complete environment adapter processes get; the entry point passes it in.
    let environment: [String: String]

    func makeAdapter(for charter: Charter, run: RunID) async throws -> any Adapter {
        let profiles = try AdapterProfiles.load(home: home)
        guard let profile = profiles.profiles[charter.adapter] else {
            throw WorkspaceError.notFound("adapter profile \(charter.adapter)")
        }
        let command = AdapterCommand(
            executable: profile.command, arguments: profile.args[charter.effort.rawValue] ?? [],
            environment: environment)
        return try AdapterConnection.launch(command)
    }
}

/// Carries out actions until binding executors land (M4): records success with output
/// `{"dryRun": true}`, so the ledger shows which actions policy and people let through.
struct DryRunExecutor: ActionExecutor {
    func execute(_ request: ExecutionRequest) async -> ExecutionOutcome {
        .succeeded(output: ["dryRun": true])
    }
}
