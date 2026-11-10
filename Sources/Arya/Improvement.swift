import AryaCore
import AryaEval
import AryaLedger
import AryaRuntime
import Foundation

// The improvement loop (ROADMAP.md M2): casebooks, rehearsal, corrections, readiness, and
// outcome metrics, wired from `AryaEval` over the home's ledger and blobs.

extension Workspace {
    // MARK: Casebooks

    /// Imports a casebook (JSON Lines) for a steward and records `casebook.imported`. The
    /// normalized casebook is stored as one blob; its version is the SHA-256 of that blob.
    public func importCasebook(steward: String, data: Data, name: String) async throws
        -> CasebookSummary
    {
        let id = try await existing(steward).id
        let (book, payload): (Casebook, CasebookImported)
        do {
            (book, payload) = try await CasebookImporter(blobs: blobs, sink: sink)
                .importCasebook(name: name, data: data, steward: id)
        } catch let error as CasebookError {
            throw WorkspaceError.rejected("casebook: \(error)")
        } catch let error as CaseError {
            throw WorkspaceError.rejected("casebook: \(error)")
        }
        return CasebookSummary(
            name: book.name, steward: steward, version: payload.version, cases: payload.cases,
            correctedFrom: nil, importedAt: try await lastEventDate())
    }

    /// Imported casebook versions, newest first, optionally for one steward.
    public func casebooks(steward: String? = nil) async throws -> [CasebookSummary] {
        try await casebookIndex().reversed()
            .filter { steward == nil || $0.steward == steward }
    }

    // MARK: Rehearsal

    /// Rehearses a steward's live charter on a casebook (default: its newest imported one):
    /// one run per case and sample with trigger `case`, tool reads served from the case,
    /// nothing executed. Records `rehearsal.*` and returns the scored result.
    public func rehearse(steward: String, casebook version: String? = nil) async throws
        -> RehearsalSummary
    {
        let record = try await existing(steward)
        let book = try await casebook(for: steward, version: version)
        let request = RehearsalRequest(
            steward: record.id, charterVersion: record.version, casebookVersion: book.version,
            samples: record.charter.gate.samples)
        let result = try await rehearser.rehearse(request, charter: record.charter)
        return RehearsalSummary(result, casebook: book)
    }

    /// Finished rehearsals of a steward, newest first.
    public func rehearsals(steward: String) async throws -> [RehearsalSummary] {
        let id = try await existing(steward).id
        let finished = try facadeState().rehearsals.finished(steward: id)
        let names = Dictionary(
            try await casebookIndex().map { ($0.version, $0.name) }, uniquingKeysWith: { a, _ in a }
        )
        return finished.map { result in
            RehearsalSummary(result, casebookName: names[result.request.casebookVersion] ?? "")
        }
    }

    // MARK: Corrections and readiness

    /// Corrects one case of a steward's casebook (default: its newest): records
    /// `case.corrected` and a memory note from `note`, and, when `expected` is given, a new
    /// casebook version with that expected result. `person` is who corrected it.
    public func correct(
        steward: String, case caseID: String, expected: Data? = nil, note: String? = nil,
        casebook version: String? = nil, by person: String = "local"
    ) async throws -> CorrectionSummary {
        let id = try await existing(steward).id
        let book = try await casebook(for: steward, version: version)
        guard let caseKey = CaseID(rawValue: caseID),
            book.cases.contains(where: { $0.id == caseKey })
        else { throw WorkspaceError.notFound(caseID) }
        let value = try expected.map { data -> JSONValue in
            guard let value = try? CanonicalJSON.decode(JSONValue.self, from: data),
                value.objectValue != nil
            else { throw WorkspaceError.rejected("expected must be a JSON object") }
            return value
        }
        guard value != nil || !(note ?? "").isEmpty else {
            throw WorkspaceError.rejected("give an expected result, a note, or both")
        }
        let text = note ?? "Corrected the expected result of \(caseID)."
        let outcome = try await Corrector(sink: sink, blobs: blobs, ambient: ambient).correct(
            CaseCorrection(caseID: caseKey, text: text, expected: value), in: book,
            steward: id, person: person)
        return CorrectionSummary(
            steward: steward, caseID: caseID, note: outcome.note.id.rawValue,
            casebook: outcome.casebook?.version ?? book.version)
    }

    /// The expected result of `caseID` with `decisions[0].choice` set to `choice`, as JSON:
    /// the shape `arya correct --choice` sends.
    public func expected(
        steward: String, case caseID: String, choice: String,
        casebook version: String? = nil
    ) async throws -> Data {
        let book = try await casebook(for: steward, version: version)
        guard let item = book.cases.first(where: { $0.id.rawValue == caseID }) else {
            throw WorkspaceError.notFound(caseID)
        }
        var object = item.expected.objectValue ?? [:]
        var decisions = object["decisions"]?.arrayValue ?? []
        var first = decisions.first?.objectValue ?? [:]
        first["choice"] = .string(choice)
        if decisions.isEmpty { decisions = [.object(first)] } else { decisions[0] = .object(first) }
        object["decisions"] = .array(decisions)
        return try CanonicalJSON.encode(JSONValue.object(object))
    }

    /// Corrects what a run did (the correction on a run thread): the run becomes a case of the
    /// steward's newest casebook (or a new `corrections` casebook) with `expected`, recorded as a
    /// new casebook version, `case.corrected`, and a memory note from `note`.
    public func correct(
        run: String, expected: Data, note: String? = nil, by person: String = "local"
    ) async throws -> CorrectionSummary {
        guard let record = try await runBook().records[RunID(unchecked: run)] else {
            throw WorkspaceError.notFound(run)
        }
        guard let value = try? CanonicalJSON.decode(JSONValue.self, from: expected),
            value.objectValue != nil
        else { throw WorkspaceError.rejected("expected must be a JSON object") }
        let outcome: CorrectionOutcome
        do {
            outcome = try await Corrector(sink: sink, blobs: blobs, ambient: ambient).correct(
                run: record.id, expected: value, note: note.flatMap { $0.isEmpty ? nil : $0 },
                person: person)
        } catch EvalError.unknownRun {
            throw WorkspaceError.notFound(run)
        }
        let body = try CanonicalJSON.decode(
            CaseCorrectedPayload.self, from: try CanonicalJSON.encode(outcome.event.payload))
        return CorrectionSummary(
            steward: record.steward.rawValue, caseID: body.caseID.rawValue,
            note: outcome.note.id.rawValue, casebook: outcome.casebook?.version ?? body.casebook)
    }

    /// What `run` recorded as its result with `decisions[0].choice` set to `choice`, as JSON:
    /// a starting point for `correct(run:expected:)` when the run chose wrong.
    public func expected(run: String, choice: String) async throws -> Data {
        let id = RunID(unchecked: run)
        guard try await runBook().records[id] != nil else { throw WorkspaceError.notFound(run) }
        var events: [Event] = []
        try reader.forEach { if $0.run == id { events.append($0) } }
        let recorded = RecordedResults(events).results[id]?.result
        var object =
            try recorded.map {
                try CanonicalJSON.decode(JSONValue.self, from: try CanonicalJSON.encode($0))
            }?.objectValue ?? [:]
        var decisions = object["decisions"]?.arrayValue ?? []
        var first = decisions.first?.objectValue ?? [:]
        first["choice"] = .string(choice)
        if decisions.isEmpty { decisions = [.object(first)] } else { decisions[0] = .object(first) }
        object["decisions"] = .array(decisions)
        return try CanonicalJSON.encode(JSONValue.object(object))
    }

    /// Marks a steward ready for live triggers (`steward.ready`), with its newest finished
    /// rehearsal of the live charter as evidence when there is one. `person` decides.
    public func markReady(steward: String, by person: String = "local") async throws
        -> StewardSummary
    {
        let record = try await existing(steward)
        let reviewed = try facadeState().rehearsals
            .finished(steward: record.id)
            .first { $0.request.charterVersion == record.version && $0.request.proposal == nil }
        try await Readiness(sink: sink).markReady(
            steward: record.id, charterVersion: record.version, reviewed: reviewed,
            person: person)
        return StewardSummary(try await existing(steward))
    }

    // MARK: Metrics

    /// A steward's outcome series in fixed windows (UTC days by default): each window's
    /// recorded metrics, action outcomes, and approval decisions.
    public func metrics(steward: String, windowSeconds: Int = 86_400) async throws
        -> MetricSeriesSummary
    {
        let record = try await existing(steward)
        let series = OutcomeMetrics.series(
            try facadeState().bySteward[record.id] ?? [], steward: record.id,
            windowMillis: Int64(max(1, windowSeconds)) * 1000)
        return MetricSeriesSummary(series, metric: record.charter.metric)
    }

    // MARK: Helpers

    var blobs: HomeBlobs { HomeBlobs(store: BlobStore(home: home)) }

    var rehearser: CasebookRehearser {
        CasebookRehearser(
            runner: RuntimeCaseRunner(loop: engine, sink: sink),
            casebooks: casebookSource, sink: sink,
            ambient: ambient)
    }

    func casebook(for steward: String, version: String?) async throws -> Casebook {
        let index = try await casebookIndex()
        let match =
            version.flatMap { wanted in index.last { $0.version == wanted } }
            ?? index.last { $0.steward == steward }
        guard let match else {
            throw WorkspaceError.notFound(version ?? "casebook for \(steward)")
        }
        return
            try await casebookSource
            .casebook(version: match.version)
    }

    /// Every `casebook.imported`, oldest first.
    func casebookIndex() async throws -> [CasebookSummary] {
        try facadeState().casebooks
    }

    /// The casebook a `casebook.imported` event recorded, else nil.
    static func casebookSummary(_ event: Event) -> CasebookSummary? {
        guard event.type.rawValue == EvalEventType.casebookImported,
            let body = try? CanonicalJSON.decode(
                CasebookImported.self, from: try CanonicalJSON.encode(event.payload))
        else { return nil }
        return CasebookSummary(
            name: body.name, steward: event.steward?.rawValue ?? "", version: body.version,
            cases: body.cases, correctedFrom: body.correctedFrom, importedAt: event.at.date)
    }

    func lastEventDate() async throws -> Date {
        try facadeState().runtime.last?.at.date ?? Date(timeIntervalSince1970: 0)
    }
}

/// The home's blob store for eval.
struct HomeBlobs: EvalBlobStore {
    let store: BlobStore
    func putBlob(_ data: Data) async throws -> String { try store.put(data) }
    func getBlob(_ hex: String) async throws -> Data { try store.get(hex) }
}

/// Imported casebooks by version, read from the ledger and blobs.
extension Workspace {
    var casebookSource: HomeCasebooks { HomeCasebooks(sink: sink, blobs: BlobStore(home: home)) }
}

struct HomeCasebooks: CasebookSource {
    let sink: any EventSink
    let blobs: BlobStore

    func casebook(version: String) async throws -> Casebook {
        for event in try await sink.events(from: 1).reversed()
        where event.type == EvalEventType.casebookImported {
            let body = try CanonicalJSON.decode(
                CasebookImported.self, from: try CanonicalJSON.encode(event.payload))
            guard body.version == version else { continue }
            return try Casebook.parse(name: body.name, data: try blobs.get(body.blob))
        }
        throw WorkspaceError.notFound("casebook \(version)")
    }
}
