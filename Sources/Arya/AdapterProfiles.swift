import AryaAdapters
import AryaCore
import AryaRuntime
import Foundation

/// Launches one adapter process per run from the home's `adapters.json` (`AdapterProfiles`).
/// The profile file is read at each run, so editing `adapters.json` needs no restart.
struct ProfileAdapterFactory: AdapterFactory {
    let home: URL
    /// The complete environment adapter processes get; the entry point passes it in.
    let environment: [String: String]

    func makeAdapter(for charter: Charter, run: RunID) async throws -> any Adapter {
        let file = home.appendingPathComponent("adapters.json")
        let command = try AdapterProfiles.load(from: file).profile(charter.adapter).command(
            name: charter.adapter, profilesFile: file.path, effort: charter.effort.rawValue,
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
