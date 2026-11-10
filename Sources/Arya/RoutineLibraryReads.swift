import AryaCore
import AryaLedger
import AryaMemory
import Foundation

// Cross-steward reads for the Routines library and the crew fan-out (connect lane, M3.6 #7
// and #10). Routines stay keyed by steward and name (decision 0060); the library groups them
// by name.

/// One routine name across every steward that has it, with how its runs went.
public struct SharedRoutineSummary: Sendable, Hashable, Codable {
    /// One steward's copy: its live version (nil: proposed only) and how many versions it has.
    public struct Use: Sendable, Hashable, Codable {
        public var steward: String
        public var liveVersion: String?
        /// The newest proposed version.
        public var latestVersion: String?
        public var versions: Int
    }

    public var name: String
    public var uses: [Use]
    /// `routine` actions naming it, and how many settled as executed or failed.
    public var runs: Int
    public var passed: Int
    public var failed: Int
    public var lastRunAt: Date?
}

/// A routine version proposed to another steward (`adoptRoutine`): the target's gate result,
/// or nil when the target has no casebook yet and the version stays proposed.
public struct RoutineAdoption: Sendable, Hashable, Codable {
    public var name: String
    public var version: String
    public var steward: String
    public var gate: RoutineGateSummary?
    /// Live in the target steward now.
    public var live: Bool { gate?.promoted == true }
}

/// A crew run: the host and each delegate, from `run.delegated` and the child runs.
public struct CrewFanoutSummary: Sendable, Hashable, Codable {
    public struct Child: Sendable, Hashable, Codable {
        public var delegation: String
        public var title: String
        public var run: String?
        /// running, completed, failed, refused, or queued (no child run yet).
        public var status: String
        public var summary: String?
        public var refused: String?
        public var seconds: Double?
    }

    public var host: RunSummary
    public var children: [Child]
}

extension Workspace {
    /// Every routine across stewards, by name.
    public func routineLibrary() async throws -> [SharedRoutineSummary] {
        let state = try facadeState()
        let library = state.routines
        var tally: [String: (runs: Int, passed: Int, failed: Int, last: Int64?)] = [:]
        var pending: [String: String] = [:]
        for event in state.events {
            switch event.type.rawValue {
            case "action.proposed":
                guard let action = event.payload["action"],
                    action["kind"]?.stringValue == "routine",
                    let name = action["params"]?["name"]?.stringValue
                else { continue }
                tally[name, default: (0, 0, 0, nil)].runs += 1
                tally[name]?.last = event.at.millis
                if let run = event.run, let id = action["id"]?.stringValue {
                    pending["\(run.rawValue)/\(id)"] = name
                }
            case "action.executed", "action.failed":
                guard let run = event.run, let id = event.payload["action"]?.stringValue,
                    let name = pending.removeValue(forKey: "\(run.rawValue)/\(id)")
                else { continue }
                if event.type.rawValue == "action.executed" {
                    tally[name]?.passed += 1
                } else {
                    tally[name]?.failed += 1
                }
            default: continue
            }
        }
        var uses: [String: [SharedRoutineSummary.Use]] = [:]
        for steward in try await stewards().map(\.id).sorted() {
            let id = StewardID(unchecked: steward)
            for name in library.names(steward: id) {
                uses[name, default: []].append(
                    SharedRoutineSummary.Use(
                        steward: steward,
                        liveVersion: library.live(steward: id, name: name)?.version,
                        latestVersion: library.versions(steward: id, name: name).last?.version,
                        versions: library.versions(steward: id, name: name).count))
            }
        }
        return uses.keys.sorted().map { name in
            let counts = tally[name]
            return SharedRoutineSummary(
                name: name, uses: uses[name] ?? [], runs: counts?.runs ?? 0,
                passed: counts?.passed ?? 0, failed: counts?.failed ?? 0,
                lastRunAt: counts?.last.map { Date(timeIntervalSince1970: Double($0) / 1000) })
        }
    }

    /// A crew run's host and delegates (decisions 0043 and 0053).
    public func crew(run: String) async throws -> CrewFanoutSummary {
        let runs = try await self.runs()
        guard let host = runs.first(where: { $0.id == run }) else {
            throw WorkspaceError.notFound(run)
        }
        let delegations = try facadeState().events.filter {
            $0.run?.rawValue == run && $0.type.rawValue == "run.delegated"
        }
        let children = delegations.map { event -> CrewFanoutSummary.Child in
            let payload = event.payload
            var child = CrewFanoutSummary.Child(
                delegation: payload["delegation"]?.stringValue ?? "",
                title: payload["title"]?.stringValue ?? "",
                run: payload["child"]?.stringValue, status: "queued",
                refused: payload["refused"]?.stringValue)
            if child.refused != nil {
                child.status = "refused"
            } else if let summary = runs.first(where: { $0.id == child.run }) {
                child.status =
                    summary.status == .running
                    ? "running" : summary.endStatus == "completed" ? "completed" : "failed"
                child.summary = summary.summary ?? summary.failureReason
                child.seconds = summary.endedAt.map { $0.timeIntervalSince(summary.startedAt) }
            }
            return child
        }
        return CrewFanoutSummary(host: host, children: children)
    }
}
