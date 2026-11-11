import AryaAdapters
import AryaCore
import AryaRuntime
import Foundation
import Security

// Connections (docs/lanes/connect.md): the systems a steward can be bound to. A connection's
// secret (an API token, a password) lives only in a `CredentialStore`, the macOS Keychain in
// the app, never in a file, a charter, or the ledger. The binding's server gets it in its
// environment as `ConnectionCredential.variable` when it starts.

/// Where connection secrets are kept, keyed by connection (binding) id.
public protocol CredentialStore: Sendable {
    /// The stored secret, or nil when none is stored.
    func credential(for connection: String) throws -> String?
    /// Stores or replaces the secret.
    func setCredential(_ secret: String, for connection: String) throws
    /// Removes the secret; removing a missing one is not an error.
    func removeCredential(for connection: String) throws
}

extension CredentialStore {
    /// Whether a secret is stored; a failed read counts as none.
    public func hasCredential(for connection: String) -> Bool {
        ((try? credential(for: connection)) ?? nil) != nil
    }
}

/// The risk an action kind has when no charter rates it (decision 0037), as its word.
public func defaultRisk(forKind kind: String) -> String {
    Risk.default(forKind: kind).rawValue
}

/// How a connection's secret reaches its server.
public enum ConnectionCredential {
    /// The environment variable a binding's MCP server reads its secret from.
    public static let variable = "ARYA_CREDENTIAL"

    /// `base` with the secret added under `variable`, or `base` unchanged when there is none.
    public static func environment(_ base: [String: String], secret: String?) -> [String: String] {
        guard let secret, !secret.isEmpty else { return base }
        var out = base
        out[variable] = secret
        return out
    }
}

/// A credential store failure, with the Security framework status.
public struct CredentialStoreError: Error, Equatable, Sendable {
    public var status: Int32
}

/// Secrets in the login Keychain as generic passwords: service `arya.connection`, account the
/// connection id.
public struct KeychainCredentialStore: CredentialStore {
    public let service: String

    public init(service: String = "arya.connection") { self.service = service }

    public func credential(for connection: String) throws -> String? {
        var query = base(connection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw CredentialStoreError(status: status)
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func setCredential(_ secret: String, for connection: String) throws {
        try removeCredential(for: connection)
        var query = base(connection)
        query[kSecValueData as String] = Data(secret.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialStoreError(status: status) }
    }

    public func removeCredential(for connection: String) throws {
        let status = SecItemDelete(base(connection) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError(status: status)
        }
    }

    private func base(_ connection: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connection,
        ]
    }
}

/// Secrets in memory, for tests, previews, and snapshots.
public struct MemoryCredentialStore: CredentialStore {
    private let secrets: Locked<[String: String]>

    public init(_ secrets: [String: String] = [:]) { self.secrets = Locked(secrets) }

    public func credential(for connection: String) throws -> String? {
        secrets.withLock { $0[connection] }
    }

    public func setCredential(_ secret: String, for connection: String) throws {
        secrets.withLock { $0[connection] = secret }
    }

    public func removeCredential(for connection: String) throws {
        secrets.withLock { $0[connection] = nil }
    }
}

/// What a connection test found: the server's name, its tools, and the ones the binding
/// declares (`read` and `actions`) that it does not offer; or one sentence on why it failed.
/// The test itself is `AryaAdapters.ConnectionProbe.binding` (docs/PROTOCOL.md, "Connection
/// testing"); this adds the declared-tool check and the secret.
public struct ConnectionTest: Hashable, Sendable {
    public var ok: Bool
    public var server: String?
    public var tools: [String]
    public var missing: [String]
    /// It serves the binding `history` convention, so rehearsals can read past work from it.
    public var servesHistory: Bool
    public var latencyMilliseconds: Int?
    /// Why it failed, for a person, ending with the server's last stderr line.
    public var problem: String?

    public init(
        ok: Bool, server: String? = nil, tools: [String] = [], missing: [String] = [],
        servesHistory: Bool = false, latencyMilliseconds: Int? = nil, problem: String? = nil
    ) {
        self.ok = ok
        self.server = server
        self.tools = tools
        self.missing = missing
        self.servesHistory = servesHistory
        self.latencyMilliseconds = latencyMilliseconds
        self.problem = problem
    }

    /// Connected and every declared tool offered.
    public var complete: Bool { ok && missing.isEmpty }

    /// Starts the server `command` with `args` and `environment` (the caller's complete
    /// environment, with the secret added by `ConnectionCredential`), lists its tools, and
    /// stops it. Nothing is recorded: a test is not a run.
    public static func run(
        command: String, args: [String], declared: [String], environment: [String: String],
        timeoutSeconds: Int = 10
    ) async -> ConnectionTest {
        let report = await ConnectionProbe.binding(
            AdapterCommand(executable: command, arguments: args, environment: environment),
            timeout: .seconds(timeoutSeconds))
        guard report.ok else { return ConnectionTest(ok: false, problem: report.problem) }
        let offered = Set(report.tools)
        var seen = Set<String>()
        return ConnectionTest(
            ok: true, server: report.server?.name, tools: report.tools,
            missing: declared.filter { !offered.contains($0) && seen.insert($0).inserted },
            servesHistory: report.servesHistory, latencyMilliseconds: report.latencyMilliseconds)
    }
}

extension Workspace {
    /// Each adapter profile's display label (`adapters.json` `label`), by profile id; profiles
    /// without one are left out, and a home without the file has none.
    public func adapterLabels() async throws -> [String: String] {
        let file = home.appendingPathComponent("adapters.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return try AdapterProfiles.load(from: file).profiles.compactMapValues(\.label)
    }
}
