import Foundation
import Testing

@testable import AryaLedger

@Test func blobPutGetExists() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let blobs = BlobStore(home: home.url)
    let data = Data("hello blobs".utf8)
    let key = try blobs.put(data)
    #expect(key == LedgerLine.hexSHA256(data))
    #expect(blobs.exists(key))
    #expect(try blobs.get(key) == data)
    #expect(blobs.path(key).path.hasSuffix("blobs/sha256/\(key.prefix(2))/\(key)"))
    #expect(try blobs.put(data) == key)
    let leftovers = try FileManager.default.contentsOfDirectory(
        atPath: blobs.path(key).deletingLastPathComponent().path)
    #expect(leftovers == [key])
}

@Test func blobErrors() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let blobs = BlobStore(home: home.url)
    let missing = String(repeating: "a", count: 64)
    #expect(!blobs.exists(missing))
    #expect(throws: BlobError.missing(missing)) { try blobs.get(missing) }
    #expect(throws: BlobError.invalidKey("../x")) { try blobs.get("../x") }
    let key = try blobs.put(Data("x".utf8))
    try Data("y".utf8).write(to: blobs.path(key))
    #expect(throws: BlobError.corrupt(key)) { try blobs.get(key) }
}
