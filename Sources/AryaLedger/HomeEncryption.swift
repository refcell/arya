import AryaCore
import CryptoKit
import Foundation
import Security

// Encryption at rest (docs/lanes/ledger.md, (G4)). One 256-bit home key, held in the Keychain,
// seals event payloads, blobs, and projection caches with AES-256-GCM. Envelopes stay in the
// clear, so the hash chain, `verify`, and the raw-byte line sieve work without the key; only
// the payload of an event that is not `system.*` is sealed. Nonces are derived from the key,
// the context, and the plaintext (a synthetic IV), so sealing is deterministic: no randomness
// is read, equal inputs seal to equal bytes, and a nonce repeats only for an identical input.

/// A home encryption key: 32 random bytes and an id that names it without revealing it.
public struct HomeKey: Sendable {
    /// `hk_` and 24 hex digits of a SHA-256 over a label and the key bytes.
    public let id: String
    let material: SymmetricKey

    /// A key from 32 bytes. Throws `HomeEncryptionError.badKey` for any other length.
    public init(bytes: [UInt8]) throws {
        guard bytes.count == 32 else { throw HomeEncryptionError.badKey }
        material = SymmetricKey(data: bytes)
        id = Self.id(for: bytes)
    }

    /// A new key from the system's secure generator (never `Ambient`: its readings are
    /// recorded on the ledger).
    public static func generate() -> HomeKey {
        let key = SymmetricKey(size: .bits256)
        let bytes = key.withUnsafeBytes { Array($0) }
        return HomeKey(unchecked: key, bytes: bytes)
    }

    private init(unchecked key: SymmetricKey, bytes: [UInt8]) {
        material = key
        id = Self.id(for: bytes)
    }

    var bytes: [UInt8] { material.withUnsafeBytes { Array($0) } }

    static func id(for bytes: [UInt8]) -> String {
        let digest = LedgerLine.hexSHA256(Array("arya.home.key|".utf8) + bytes)
        return "hk_" + digest.prefix(24)
    }
}

/// Where home keys are kept, by key id.
public protocol HomeKeyStore: Sendable {
    /// The key with `id`, or nil when none is stored.
    func key(_ id: String) throws -> HomeKey?
    /// Stores `key` under its id, replacing any stored copy.
    func save(_ key: HomeKey) throws
}

/// Home keys in memory, for tests and snapshots.
public struct MemoryHomeKeyStore: HomeKeyStore {
    private let keys: Locked<[String: [UInt8]]>

    public init() { keys = Locked([:]) }

    public func key(_ id: String) throws -> HomeKey? {
        try keys.withLock { $0[id] }.map { try HomeKey(bytes: $0) }
    }

    public func save(_ key: HomeKey) throws { keys.withLock { $0[key.id] = key.bytes } }
}

/// Home keys in the login Keychain as generic passwords: service `arya.home`, account the
/// key id, readable after the first unlock so a login-item `arya serve` can open the home.
public struct KeychainHomeKeyStore: HomeKeyStore {
    public let service: String

    public init(service: String = "arya.home") { self.service = service }

    public func key(_ id: String) throws -> HomeKey? {
        var query = base(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw HomeEncryptionError.keychain(status: status)
        }
        return try HomeKey(bytes: Array(data))
    }

    public func save(_ key: HomeKey) throws {
        let deleted = SecItemDelete(base(key.id) as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else {
            throw HomeEncryptionError.keychain(status: deleted)
        }
        var query = base(key.id)
        query[kSecValueData as String] = Data(key.bytes)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw HomeEncryptionError.keychain(status: status) }
    }

    private func base(_ id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
    }
}

/// Seals and opens bytes with a home key. The box is CryptoKit's combined form (12-byte nonce,
/// ciphertext, 16-byte tag); the context is authenticated, so a box cannot be moved to another
/// event or file.
public struct HomeCipher: Sendable {
    public let key: HomeKey
    private let sealKey: SymmetricKey
    private let nonceKey: SymmetricKey

    public init(key: HomeKey) {
        self.key = key
        sealKey = Self.derive(key.material, "arya.seal.v1")
        nonceKey = Self.derive(key.material, "arya.nonce.v1")
    }

    public func seal(_ plain: [UInt8], context: String) throws -> [UInt8] {
        let aad = Array(context.utf8)
        let mac = HMAC<SHA256>.authenticationCode(
            for: aad + [0] + plain, using: nonceKey)
        let nonce = try AES.GCM.Nonce(data: Array(mac).prefix(12))
        let box = try AES.GCM.seal(plain, using: sealKey, nonce: nonce, authenticating: aad)
        guard let combined = box.combined else { throw HomeEncryptionError.badBox }
        return Array(combined)
    }

    public func open(_ box: [UInt8], context: String) throws -> [UInt8] {
        do {
            let sealed = try AES.GCM.SealedBox(combined: box)
            return Array(
                try AES.GCM.open(sealed, using: sealKey, authenticating: Array(context.utf8)))
        } catch {
            throw HomeEncryptionError.badBox
        }
    }

    private static func derive(_ key: SymmetricKey, _ label: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key, info: Array(label.utf8), outputByteCount: 32)
    }
}

/// The sealed form of an event payload: `{"sealed":{"box":…,"key":…,"v":1}}`.
public enum SealedPayload {
    /// The authenticated context of an event's payload.
    static func context(id: EventID, seq: Int64, type: EventType) -> String {
        "event|\(id.rawValue)|\(seq)|\(type.rawValue)"
    }

    /// Whether `type` is sealed in an encrypted home: everything but `system.*`, which
    /// `verify` and checkpoint checks must read without the key.
    public static func applies(to type: EventType) -> Bool {
        !type.rawValue.hasPrefix("system.")
    }

    static func seal(_ payload: JSONValue, cipher: HomeCipher, context: String) throws -> JSONValue
    {
        let box = try cipher.seal(Array(try CanonicalJSON.encode(payload)), context: context)
        return [
            "sealed": [
                "v": 1, "key": .string(cipher.key.id),
                "box": .string(Data(box).base64EncodedString()),
            ]
        ]
    }

    /// The key id and box of a sealed payload, or nil for a payload in the clear.
    public static func parts(_ payload: JSONValue) -> (key: String, box: [UInt8])? {
        guard case .object(let outer) = payload, outer.count == 1,
            case .object(let inner)? = outer["sealed"], inner.count == 3, inner["v"] == 1,
            case .string(let key)? = inner["key"], case .string(let box)? = inner["box"],
            let bytes = Data(base64Encoded: box)
        else { return nil }
        return (key, Array(bytes))
    }

    /// Whether `event` carries a sealed payload.
    public static func isSealed(_ event: Event) -> Bool { parts(event.payload) != nil }
}

/// The home's encryption setting in `keys/encryption.json`: `{"algorithm","key","v"}`.
public struct HomeEncryptionConfig: Codable, Hashable, Sendable {
    public var v: Int
    public var algorithm: String
    public var key: String

    public static let algorithm = "AES-256-GCM"

    enum CodingKeys: String, CodingKey { case v, algorithm, key }
}

/// `system.encryption.enabled`: the home seals payloads, blobs, and caches with `key` from
/// this event on (actor: the person who enabled it).
public struct SystemEncryptionEnabled: EventPayload {
    public static let type = EventType.systemEncryptionEnabled
    public var algorithm: String
    public var key: String

    public init(algorithm: String = HomeEncryptionConfig.algorithm, key: String) {
        self.algorithm = algorithm
        self.key = key
    }

    enum CodingKeys: String, CodingKey { case algorithm, key }
}

/// Encryption errors. None carries key material or paths.
public enum HomeEncryptionError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The home is sealed with `key`, and no key store registered for it holds that key.
    case locked(key: String)
    /// Key bytes were not 32 bytes long.
    case badKey
    /// A box failed to open: the wrong key, a damaged file, or a moved box.
    case badBox
    /// `keys/encryption.json` could not be read.
    case badConfig
    /// A Keychain call failed with this Security framework status.
    case keychain(status: Int32)

    public var description: String {
        switch self {
        case .locked(let key): "the home is encrypted and key \(key) is not available"
        case .badKey: "a home key must be 32 bytes"
        case .badBox: "sealed data did not open: wrong key or damaged bytes"
        case .badConfig: "keys/encryption.json is unreadable"
        case .keychain(let status): "Keychain call failed (status \(status))"
        }
    }
}

/// Per-home encryption: the setting, the key stores registered by the process that opened the
/// home, sealed files, enabling, and migration.
///
/// Readers and writers find a home's cipher here by home path, so every `LedgerReader`,
/// `LedgerStore`, `BlobStore`, and `ProjectionCache` for that home seals and opens without
/// being handed a key. A home with no setting is never sealed and needs no key store.
public enum HomeEncryption {
    struct Entry {
        var keys: (any HomeKeyStore)?
        var ciphers: [String: HomeCipher] = [:]
    }

    private static let homes = Locked<[String: Entry]>([:])

    static func path(_ home: URL) -> String { home.standardizedFileURL.path }

    /// Where the setting lives.
    public static func configURL(_ home: URL) -> URL {
        home.appendingPathComponent("keys", isDirectory: true)
            .appendingPathComponent("encryption.json")
    }

    /// The home's setting, or nil when it is not encrypted.
    public static func config(_ home: URL) throws -> HomeEncryptionConfig? {
        guard let data = FileManager.default.contents(atPath: configURL(home).path) else {
            return nil
        }
        guard let config = try? JSONDecoder().decode(HomeEncryptionConfig.self, from: data),
            config.v == 1, config.algorithm == HomeEncryptionConfig.algorithm
        else { throw HomeEncryptionError.badConfig }
        return config
    }

    /// Registers where this process finds `home`'s keys. Call once when opening a home.
    public static func register(home: URL, keys: any HomeKeyStore) {
        homes.withLock { $0[path(home)] = Entry(keys: keys) }
    }

    /// The cipher for `key` in `home`, loaded once from the registered key store.
    static func cipher(_ home: URL, key: String) throws -> HomeCipher {
        let path = path(home)
        if let found = homes.withLock({ $0[path]?.ciphers[key] }) { return found }
        guard let store = homes.withLock({ $0[path]?.keys }), let loaded = try store.key(key),
            loaded.id == key
        else { throw HomeEncryptionError.locked(key: key) }
        let cipher = HomeCipher(key: loaded)
        homes.withLock { $0[path, default: Entry()].ciphers[key] = cipher }
        return cipher
    }

    /// The cipher new data is sealed with, or nil when the home is not encrypted.
    static func sealing(_ home: URL) throws -> HomeCipher? {
        guard let config = try config(home) else { return nil }
        return try cipher(home, key: config.key)
    }

    /// `event` with its payload opened, or unchanged when it is in the clear.
    static func opened(_ event: Event, home: URL) throws -> Event {
        guard let parts = SealedPayload.parts(event.payload) else { return event }
        let cipher = try cipher(home, key: parts.key)
        let plain = try cipher.open(
            parts.box,
            context: SealedPayload.context(id: event.id, seq: event.seq, type: event.type))
        var out = event
        out.payload = try JSONParser.parse(plain)
        return out
    }

    // MARK: Sealed files

    static let fileMagic = Array("arya-sealed 1 ".utf8)

    /// Whether `data` is a sealed file.
    public static func isSealedFile(_ data: some Collection<UInt8>) -> Bool {
        data.starts(with: fileMagic)
    }

    /// `plain` as a sealed file: `arya-sealed 1 <key>\n` and the box.
    static func sealFile(_ plain: [UInt8], cipher: HomeCipher, context: String) throws -> [UInt8] {
        fileMagic + Array(cipher.key.id.utf8) + [10] + (try cipher.seal(plain, context: context))
    }

    /// The plaintext of a file's bytes: opened when sealed, unchanged otherwise.
    static func openFile(_ data: [UInt8], home: URL, context: String) throws -> [UInt8] {
        guard isSealedFile(data) else { return data }
        let rest = data[fileMagic.count...]
        guard let newline = rest.firstIndex(of: 10) else { throw HomeEncryptionError.badBox }
        let key = String(decoding: rest[rest.startIndex..<newline], as: UTF8.self)
        return try cipher(home, key: key).open(Array(rest[(newline + 1)...]), context: context)
    }

    /// Writes `plain` to `url` atomically, sealed when the home is encrypted.
    static func write(_ plain: [UInt8], to url: URL, home: URL, context: String) throws {
        let bytes = try sealing(home).map { try sealFile(plain, cipher: $0, context: context) }
        try FileIO.atomicWrite(Data(bytes ?? plain), to: url)
    }

    // MARK: Enabling and migration

    /// Turns encryption on: stores a new key in `keys`, writes the setting, records
    /// `system.encryption.enabled`, then seals existing blobs and seeds and drops plaintext
    /// caches (they rebuild sealed). Events written before stay in the clear (the hash chain
    /// and signed checkpoints cover their bytes). Enabling an encrypted home returns its
    /// setting unchanged.
    @discardableResult
    public static func enable(
        store: LedgerStore, keys: any HomeKeyStore, actor: Actor = .local,
        key: HomeKey = .generate()
    ) throws -> HomeEncryptionConfig {
        let home = store.home
        register(home: home, keys: keys)
        if let existing = try config(home) { return existing }
        try keys.save(key)
        let config = HomeEncryptionConfig(
            v: 1, algorithm: HomeEncryptionConfig.algorithm, key: key.id)
        let url = configURL(home)
        try FileIO.makeDirectory(url.deletingLastPathComponent())
        try FileIO.atomicWrite(try CanonicalJSON.encode(config), to: url)
        try store.append(EventDraft(SystemEncryptionEnabled(key: key.id), actor: actor))
        try migrate(home)
        return config
    }

    /// Seals every plaintext blob and seed in place and removes plaintext cache files.
    /// Returns how many files it sealed or removed. Safe to run again.
    @discardableResult
    public static func migrate(_ home: URL) throws -> Int {
        guard let cipher = try sealing(home) else { return 0 }
        var changed = 0
        let blobs = BlobStore(home: home)
        for hex in try blobs.keys() {
            let url = blobs.path(hex)
            guard let data = FileManager.default.contents(atPath: url.path),
                !isSealedFile(data), LedgerLine.hexSHA256(data) == hex
            else { continue }
            let sealed = try sealFile(Array(data), cipher: cipher, context: BlobStore.context(hex))
            try FileIO.atomicWrite(Data(sealed), to: url)
            changed += 1
        }
        let cache = ProjectionCache(home: home)
        for url in jsonFiles(cache.directory) {
            guard let data = FileManager.default.contents(atPath: url.path), !isSealedFile(data)
            else { continue }
            try? FileManager.default.removeItem(at: url)
            changed += 1
        }
        let seeds = home.appendingPathComponent("archive/seeds", isDirectory: true)
        for dir in subdirectories(seeds) {
            for url in jsonFiles(dir) {
                guard let data = FileManager.default.contents(atPath: url.path),
                    !isSealedFile(data)
                else { continue }
                let name = url.deletingPathExtension().lastPathComponent
                let sealed = try sealFile(
                    Array(data), cipher: cipher, context: ProjectionCache.context(name))
                try FileIO.atomicWrite(Data(sealed), to: url)
                changed += 1
            }
        }
        return changed
    }

    private static func jsonFiles(_ dir: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.sorted().filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .map { dir.appendingPathComponent($0) }
    }

    private static func subdirectories(_ dir: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.sorted().filter { !$0.hasPrefix(".") }
            .map { dir.appendingPathComponent($0, isDirectory: true) }
    }
}
