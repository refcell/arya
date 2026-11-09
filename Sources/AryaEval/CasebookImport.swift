import AryaCore
import AryaRuntime
import Foundation

/// The payload of a `casebook.imported` event.
public struct CasebookImported: Hashable, Sendable, Codable {
    public var v: Int
    public var name: String
    public var version: String
    /// Blob holding the normalized casebook (equal to `version`, the content hash).
    public var blob: String
    public var cases: Int

    public init(name: String, version: String, blob: String, cases: Int) {
        self.v = 1
        self.name = name
        self.version = version
        self.blob = blob
        self.cases = cases
    }

    enum CodingKeys: String, CodingKey {
        case v, name, version, blob, cases
    }
}

/// Content-addressed blob storage. A stand-in until `AryaLedger` publishes its blob store; the
/// facade adapts the real store to it.
public protocol EvalBlobStore: Sendable {
    /// Stores `data` and returns its lowercase hex SHA-256.
    func putBlob(_ data: Data) async throws -> String
}

/// Records casebooks into blobs and the ledger.
public struct CasebookImporter: Sendable {
    public var blobs: any EvalBlobStore
    public var sink: any EventSink

    public init(blobs: any EvalBlobStore, sink: any EventSink) {
        self.blobs = blobs
        self.sink = sink
    }

    /// Parses, stores, and records a casebook; returns it with the recorded payload.
    @discardableResult
    public func importCasebook(
        name: String, data: Data, steward: StewardID?, actor: RuntimeActor = .localUser
    ) async throws -> (Casebook, CasebookImported) {
        let book = try Casebook.parse(name: name, data: data)
        let blob = try await blobs.putBlob(try book.normalizedData())
        let payload = CasebookImported(
            name: name, version: book.version, blob: blob, cases: book.cases.count)
        _ = try await sink.append(
            RuntimeEventDraft(
                type: "casebook.imported", steward: steward, actor: actor,
                payload: try CanonicalJSON.jsonValue(payload)))
        return (book, payload)
    }
}
