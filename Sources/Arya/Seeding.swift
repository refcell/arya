import AryaAdapters
import AryaCore
import AryaRuntime
import Foundation

// Seeding: one process writes a demo home's whole history (decision 0052). Every adapter is
// the fake adapter served in process from a script held in memory, so a run costs no process
// launch, and the caller moves the clock between steps with `Ambient.advance(to:)`.

extension Workspace {
    /// Opens `home` with every charter's adapter served in process by the fake adapter, from
    /// `scripts` by adapter name; a charter naming another adapter fails its run. Actions run
    /// dry, as in `open(home:environment:ambient:keys:)`. For tools that seed demo homes.
    public static func openForSeeding(
        home: URL, ambient: Ambient, scripts: [String: FakeScript]
    ) async throws -> Workspace {
        try HomeLayout.create(at: home)
        let leases = try FileRunLeases(directory: HomeLayout.leases(home))
        return try await open(
            home: home,
            wiring: Wiring(
                ambient: ambient, adapters: ScriptAdapterFactory(scripts: scripts),
                executor: DryRunExecutor(), leases: leases))
    }
}

/// Serves each run from the in-memory script its charter's adapter names.
struct ScriptAdapterFactory: AdapterFactory {
    let scripts: [String: FakeScript]

    func makeAdapter(for charter: Charter, run: RunID) async throws -> any Adapter {
        guard let script = scripts[charter.adapter] else {
            throw WorkspaceError.rejected("no seeding script for adapter \(charter.adapter)")
        }
        return FakeAdapter(script: script)
    }
}
