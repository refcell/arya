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

/// What a connection test found: the tools the server lists, and the ones the binding
/// declares (`read` and `actions`) that it does not offer.
public struct ConnectionProbe: Hashable, Sendable {
    public var tools: [String]
    public var missing: [String]

    public init(tools: [String], missing: [String]) {
        self.tools = tools
        self.missing = missing
    }

    /// Whether every declared tool is offered.
    public var complete: Bool { missing.isEmpty }
}

/// Why a connection test failed.
public enum ConnectionProbeError: Error, Equatable, Sendable {
    /// The server could not be started (`detail` is the system's sentence).
    case launch(String)
    /// The server did not answer `tools/list` within the time allowed.
    case timedOut(seconds: Int)
    /// The server answered with an error or exited.
    case failed(String)
}

extension ConnectionProbe {
    /// Starts the server `command` with `args` and `environment` (the caller's complete
    /// environment, with the secret added by `ConnectionCredential`), lists its tools, and
    /// stops it. Nothing is recorded: a test is not a run. The timeout uses a sleep, never a
    /// clock reading, so it cannot change what a run records.
    public static func run(
        command: String, args: [String], declared: [String], environment: [String: String],
        timeoutSeconds: Int = 10
    ) async throws -> ConnectionProbe {
        let upstream: ProcessToolUpstream
        do {
            upstream = try ProcessToolUpstream(
                command: command, args: args, environment: environment)
        } catch {
            throw ConnectionProbeError.launch(error.localizedDescription)
        }
        defer { Task { await upstream.close() } }
        let listed = try await withThrowingTaskGroup(of: [JSONValue]?.self) { group in
            group.addTask { try await upstream.listTools() }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                return nil
            }
            defer { group.cancelAll() }
            do {
                guard let first = try await group.next(), let tools = first else {
                    await upstream.close()
                    throw ConnectionProbeError.timedOut(seconds: timeoutSeconds)
                }
                return tools
            } catch let error as ConnectionProbeError {
                throw error
            } catch {
                throw ConnectionProbeError.failed(Self.sentence(error))
            }
        }
        let tools = listed.compactMap { $0["name"]?.stringValue }
        let offered = Set(tools)
        var seen = Set<String>()
        let missing = declared.filter { !offered.contains($0) && seen.insert($0).inserted }
        return ConnectionProbe(tools: tools, missing: missing)
    }

    private static func sentence(_ error: any Error) -> String {
        if let rpc = error as? RPCError { return rpc.message }
        return String(describing: error)
    }
}
