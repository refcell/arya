import AryaCore
import AryaRuntime

/// One imported casebook version.
public struct CasebookRecord: Hashable, Sendable {
    public var imported: CasebookImported
    public var steward: StewardID?
    public var seq: Int
    public var actor: RuntimeActor
}

/// Folds `casebook.imported` events: every version, and the latest version per name.
public struct CasebookBook: Sendable {
    /// Records by version. Re-importing the same content keeps the first record.
    public private(set) var versions: [String: CasebookRecord] = [:]
    /// The latest imported version of each name.
    public private(set) var latest: [String: String] = [:]

    public init() {}

    public init(_ events: [RuntimeEvent]) throws {
        for event in events { try apply(event) }
    }

    public mutating func apply(_ event: RuntimeEvent) throws {
        guard event.type == EvalEventType.casebookImported else { return }
        let body = try EvalPayload.decode(CasebookImported.self, event.payload)
        if versions[body.version] == nil {
            versions[body.version] = CasebookRecord(
                imported: body, steward: event.draft.steward, seq: event.seq,
                actor: event.draft.actor)
        }
        latest[body.name] = body.version
    }

    /// Casebook names, sorted, with their latest record.
    public var names: [CasebookRecord] {
        latest.keys.sorted().compactMap { latest[$0].flatMap { versions[$0] } }
    }

    /// Every version of `name`, oldest first.
    public func history(_ name: String) -> [CasebookRecord] {
        versions.values.filter { $0.imported.name == name }.sorted { $0.seq < $1.seq }
    }
}

/// Loads imported casebooks from blobs, checking that the content still hashes to its version.
public struct StoredCasebooks: CasebookSource {
    public var sink: any EventSink
    public var blobs: any EvalBlobStore

    public init(sink: any EventSink, blobs: any EvalBlobStore) {
        self.sink = sink
        self.blobs = blobs
    }

    public func casebook(version: String) async throws -> Casebook {
        let book = try CasebookBook(try await sink.events(from: 1))
        guard let record = book.versions[version] else {
            throw EvalError.unknownCasebook(version)
        }
        let data = try await blobs.getBlob(record.imported.blob)
        let casebook = try Casebook.parse(name: record.imported.name, data: data)
        guard casebook.version == version else {
            throw EvalError.casebookMismatch(expected: version, actual: casebook.version)
        }
        return casebook
    }

    /// The latest version imported under `name`.
    public func latest(name: String) async throws -> Casebook {
        let book = try CasebookBook(try await sink.events(from: 1))
        guard let version = book.latest[name] else { throw EvalError.unknownCasebook(name) }
        return try await casebook(version: version)
    }
}
