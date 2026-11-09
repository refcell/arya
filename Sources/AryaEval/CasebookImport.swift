import AryaCore
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

/// Where eval writes blobs and ledger events. A stand-in until `AryaLedger` publishes its
/// store; the facade adapts the real ledger to it.
public protocol EvalRecorder: Sendable {
    /// Stores `data` content-addressed and returns its lowercase hex SHA-256.
    func putBlob(_ data: Data) async throws -> String
    /// Appends an event with the local user as actor unless the caller names another.
    func append(type: String, steward: StewardID?, payload: JSONValue) async throws
}

/// Records casebooks into blobs and the ledger.
public struct CasebookImporter: Sendable {
    public var recorder: any EvalRecorder

    public init(recorder: any EvalRecorder) {
        self.recorder = recorder
    }

    /// Parses, stores, and records a casebook; returns it with the recorded payload.
    @discardableResult
    public func importCasebook(
        name: String, data: Data, steward: StewardID?
    ) async throws -> (Casebook, CasebookImported) {
        let book = try Casebook.parse(name: name, data: data)
        let blob = try await recorder.putBlob(try book.normalizedData())
        let payload = CasebookImported(
            name: name, version: book.version, blob: blob, cases: book.cases.count)
        try await recorder.append(
            type: "casebook.imported", steward: steward,
            payload: try CanonicalJSON.jsonValue(payload))
        return (book, payload)
    }
}
