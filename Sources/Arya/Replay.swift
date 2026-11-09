import Foundation

/// The result of replaying a run.
public struct ReplaySummary: Sendable, Hashable, Codable {
    /// Where a replay first differed from the recording.
    public struct Difference: Sendable, Hashable, Codable {
        /// Position among the run's events, from 0.
        public var index: Int
        /// Ledger `seq` of the recorded event, when there is one.
        public var seq: Int?
        /// Event type (recorded, else replayed).
        public var type: String
        /// Dotted path of the first differing field, for example `payload.status`.
        public var field: String
        /// Recorded and replayed events as canonical JSON (`{"type","payload"}`), or empty.
        public var recorded: String
        public var replayed: String
    }

    /// Run id.
    public var run: String
    /// Events compared (the longer of the two sequences).
    public var events: Int
    /// The first difference; empty when the replay matched the recording exactly.
    public var divergences: [Difference]
}

extension Workspace {
    /// Replays a run from the ledger alone and reports the first difference from the
    /// recording. Backed by `AryaEval`'s replay engine once it lands (eval lane).
    public func replay(run id: String) async throws -> ReplaySummary {
        throw WorkspaceError.unavailable("replay")
    }
}
