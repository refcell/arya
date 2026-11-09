import Arya
import Foundation

/// What the app reads and writes through the facade. `Workspace` conforms; the tests use an
/// in-memory `FakeWorkspaceSource`.
protocol WorkspaceSource: Sendable {
    /// A short label for the window subtitle: the home's folder name or "Preview".
    var label: String { get }
    func stewards() async throws -> [StewardSummary]
    func runs(steward: String?) async throws -> [RunSummary]
    func approvals(includeDecided: Bool) async throws -> [ApprovalSummary]
    func pauseSteward(_ id: String) async throws
    func resumeSteward(_ id: String) async throws
    /// Starts a manual run and returns once it finishes or fails.
    func startRun(steward: String, input: String) async throws -> RunSummary
    func approve(_ id: String, note: String?) async throws -> ApprovalSummary
    func deny(_ id: String, note: String?) async throws -> ApprovalSummary
    func ledger(from seq: Int, limit: Int?) async throws -> [LedgerEntry]
    func events(from seq: Int) -> AsyncThrowingStream<LedgerEntry, Error>
    func verifyLedger() async throws -> LedgerCheck
    /// Each steward's charter effort (`low`, `medium`, `high`) by steward id.
    func efforts() async throws -> [String: String]
    /// Changes a steward's charter effort.
    func setEffort(_ effort: String, steward: String) async throws
    /// Records one feature-view write, attributed to the local person.
    func record(_ write: FeatureWrite) async throws
    /// A routine version's body, or nil if it is missing.
    func routineBody(steward: String, name: String, version: String) async throws -> String?
    /// One case's expected result in a casebook version, or nil if it is missing.
    func expectedResult(casebook: String, caseID: String) async throws -> FeatureJSON?
    /// Replays a run from the ledger alone.
    func replayRun(_ run: String) async throws -> FeatureReplayResult
    /// One event's inspector detail.
    func eventDetail(seq: Int) async throws -> FeatureEventDetail?
}

extension WorkspaceSource {
    func routineBody(steward: String, name: String, version: String) async throws -> String? {
        throw FeatureReadError.unavailable("routine bodies")
    }

    func expectedResult(casebook: String, caseID: String) async throws -> FeatureJSON? {
        throw FeatureReadError.unavailable("expected results")
    }

    func replayRun(_ run: String) async throws -> FeatureReplayResult {
        throw FeatureReadError.unavailable("replay")
    }

    func eventDetail(seq: Int) async throws -> FeatureEventDetail? {
        throw FeatureReadError.unavailable("event detail")
    }
}

extension Workspace: WorkspaceSource {
    nonisolated var label: String { home.lastPathComponent }

    func efforts() async throws -> [String: String] {
        var efforts: [String: String] = [:]
        for steward in try await stewards() {
            efforts[steward.id] = try await effort(for: steward.id)
        }
        return efforts
    }

    func setEffort(_ effort: String, steward: String) async throws {
        try await setEffort(effort, for: steward, by: Self.person)
    }

    /// The person the app acts for until person bindings land (M4).
    nonisolated static let person = "local"

    func record(_ write: FeatureWrite) async throws {
        let person = Self.person
        switch write {
        case .approve(let approval):
            _ = try await approve(approval, note: nil)
        case .deny(let approval, let reason):
            _ = try await deny(approval, note: reason.isEmpty ? nil : reason)
        case .acceptProposal(let id):
            _ = try await acceptProposal(id, by: person)
        case .rejectProposal(let id, let reason):
            _ = try await rejectProposal(id, reason: reason.isEmpty ? nil : reason, by: person)
        case .overrideProposal(let id, let reason):
            _ = try await overrideProposal(id, reason: reason, by: person)
        case .retractMemory:
            throw WorkspaceError.unavailable("retracting memory")
        case .correctCase(let correction):
            _ = try await correct(
                steward: correction.steward, case: correction.caseID,
                expected: try correction.expected.map(Self.canonical),
                note: correction.text.isEmpty ? nil : correction.text,
                casebook: correction.casebook, by: person)
        case .markReady(let steward, _, _):
            // The facade checks the reviewed rehearsal and live charter version itself.
            _ = try await markReady(steward: steward, by: person)
        case .proposeCharter(let proposal):
            _ = try await proposeCharter(
                steward: proposal.steward, charter: try Self.canonical(proposal.charter),
                baseVersion: proposal.baseVersion, title: proposal.title, reason: proposal.reason,
                by: person)
        case .startRun(let steward, let input):
            _ = try await startRun(steward: steward, input: input)
        case .rehearse(let steward, let casebook):
            _ = try await rehearse(steward: steward, casebook: casebook)
        case .answer(let approval, let text):
            // A person binding's answer to a question approves it with the answer as the note.
            _ = try await approve(approval, note: text)
        case .createSteward(let draft):
            _ = try await createSteward(draft)
        }
    }

    func routineBody(steward: String, name: String, version: String) async throws -> String? {
        try await routineContent(steward: steward, name: name, version: version)
    }

    func expectedResult(casebook: String, caseID: String) async throws -> FeatureJSON? {
        guard let data = try await caseExpected(casebook: casebook, case: caseID) else {
            return nil
        }
        return try JSONDecoder().decode(FeatureJSON.self, from: data)
    }

    func replayRun(_ run: String) async throws -> FeatureReplayResult {
        Self.featureReplay(try await replay(run: run))
    }

    func eventDetail(seq: Int) async throws -> FeatureEventDetail? {
        guard let detail = try await event(seq: seq) else { return nil }
        return FeatureEventDetail(
            payloadText: detail.payloadText, hash: detail.hash, prev: detail.prev,
            step: detail.step.map {
                FeatureEventDetail.Step(
                    run: $0.run, index: $0.index, count: $0.count, title: $0.title)
            })
    }

    /// A facade replay summary in the feature views' shape.
    nonisolated static func featureReplay(_ summary: ReplaySummary) -> FeatureReplayResult {
        FeatureReplayResult(
            run: summary.run, events: summary.events,
            divergences: summary.divergences.map {
                FeatureReplayResult.Divergence(
                    index: $0.index, seq: $0.seq, type: $0.type, field: $0.field,
                    recorded: $0.recorded, replayed: $0.replayed)
            })
    }

    nonisolated static func canonical(_ json: FeatureJSON) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(json)
    }
}
