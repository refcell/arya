import Arya
import Foundation

/// The Connections screen's read model, built from the ledger alone: every system connection
/// the workspace knows (from any steward's charter, past or live), what each can read and do
/// with the risk of each action, which stewards are connected to it now, and the adapters
/// stewards run on. Connecting or disconnecting a steward is a gated charter proposal, never an
/// in-place edit.
struct ConnectionsCatalog: Hashable, Sendable {
    /// One system connection (an MCP server binding).
    struct Entry: Hashable, Sendable, Identifiable {
        var id: String
        var command: String
        var args: [String]
        /// Tools a harness may call during a run.
        var read: [String]
        /// Action kinds arya may execute through it, each with its risk.
        var actions: [Action]
        /// Stewards whose live charter binds it, by id.
        var connected: [String]
        /// The server may use the network when sandboxed.
        var network: Bool

        /// The command line, as a person would type it.
        var commandLine: String { ([command] + args).joined(separator: " ") }
        /// Every tool the binding declares, for the connection test.
        var declared: [String] { read + actions.map(\.kind) }
    }

    /// An action kind and its risk (`low`, `medium`, `high`): recorded or charter-rated, else
    /// the kind's default (decision 0037).
    struct Action: Hashable, Sendable {
        var kind: String
        var risk: String
    }

    /// An adapter and the stewards whose live charter runs on it.
    struct Adapter: Hashable, Sendable {
        var name: String
        var stewards: [String]
    }

    var entries: [Entry]
    var adapters: [Adapter]
    /// Live charters by steward id.
    var live: [String: LiveCharter]
    /// Person bindings that relay through a connection, by connection id then steward id.
    var relays: [String: [String: [String]]]

    init(events: [FeatureEvent]) {
        let known = NewStewardCatalog(events: events)
        var stewards: [String] = []
        for event in events where event.type == "steward.created" {
            if let id = event.steward, !stewards.contains(id) { stewards.append(id) }
        }
        var live: [String: LiveCharter] = [:]
        for id in stewards { live[id] = LiveCharter.find(events: events, steward: id) }
        self.live = live
        var connected: [String: [String]] = [:]
        var network: [String: Bool] = [:]
        var relays: [String: [String: [String]]] = [:]
        var adapters: [(String, [String])] = []
        for id in stewards {
            guard let charter = live[id]?.charter else { continue }
            for binding in charter["bindings"]?.array ?? [] {
                guard let bindingID = binding["id"]?.string else { continue }
                if binding["kind"]?.string == "person" {
                    if let via = binding["via"]?.string {
                        relays[via, default: [:]][id, default: []].append(bindingID)
                    }
                    continue
                }
                connected[bindingID, default: []].append(id)
                if binding["network"]?.bool == true { network[bindingID] = true }
            }
            let adapter = charter["adapter"]?.string ?? "default"
            if let index = adapters.firstIndex(where: { $0.0 == adapter }) {
                adapters[index].1.append(id)
            } else {
                adapters.append((adapter, [id]))
            }
        }
        self.relays = relays
        self.adapters = adapters.map { Adapter(name: $0.0, stewards: $0.1) }
        entries = known.connections.map { connection in
            Entry(
                id: connection.id, command: connection.command, args: connection.args,
                read: connection.read,
                actions: connection.actions.map {
                    Action(kind: $0, risk: known.risks[$0] ?? defaultRisk(forKind: $0))
                },
                connected: connected[connection.id] ?? [], network: network[connection.id] ?? false)
        }
    }

    /// `entry` as `steward` sees it: its own binding's tools and actions when connected (the
    /// catalog keeps the newest declaration across stewards), else the catalog's.
    func entry(_ entry: Entry, for steward: String?) -> Entry {
        guard let steward,
            let own = (live[steward]?.charter["bindings"]?.array ?? []).first(where: {
                $0["id"]?.string == entry.id && $0["kind"]?.string != "person"
            })
        else { return entry }
        var out = entry
        out.command = own["command"]?.string ?? entry.command
        out.args = own["args"]?.array?.compactMap(\.string) ?? entry.args
        out.read = own["read"]?.array?.compactMap(\.string) ?? entry.read
        let risks = Dictionary(
            entry.actions.map { ($0.kind, $0.risk) }, uniquingKeysWith: { first, _ in first })
        out.actions = (own["actions"]?.array?.compactMap(\.string) ?? []).map {
            Action(kind: $0, risk: risks[$0] ?? defaultRisk(forKind: $0))
        }
        return out
    }

    /// Whether `steward`'s live charter binds `entry`.
    func isConnected(_ entry: Entry, steward: String) -> Bool {
        entry.connected.contains(steward)
    }

    /// Why `steward` cannot be disconnected from `entry`, or nil when it can: people reached
    /// through it would lose their channel.
    func disconnectBlocker(_ entry: Entry, steward: String) -> String? {
        let people = relays[entry.id]?[steward] ?? []
        guard !people.isEmpty else { return nil }
        return "Messages to \(people.joined(separator: ", ")) go through \(entry.id)."
    }

    /// A proposal adding `entry` to `steward`'s live charter, or nil when there is no live
    /// charter or it is already bound.
    func connectProposal(_ entry: Entry, steward: String) -> CharterProposal? {
        guard let live = live[steward], case .object(var charter) = live.charter,
            !isConnected(entry, steward: steward)
        else { return nil }
        var binding: [String: FeatureJSON] = [
            "id": .string(entry.id), "kind": "mcp", "command": .string(entry.command),
            "args": .array(entry.args.map(FeatureJSON.string)),
            "read": .array(entry.read.map(FeatureJSON.string)),
            "actions": .array(entry.actions.map { .string($0.kind) }),
        ]
        if entry.network { binding["network"] = .bool(true) }
        charter["bindings"] = .array((live.charter["bindings"]?.array ?? []) + [.object(binding)])
        return CharterProposal(
            steward: steward, baseVersion: live.version, charter: .object(charter),
            title: "Connect \(entry.id)", reason: Self.connectReason(entry))
    }

    /// A proposal removing `entry` from `steward`'s live charter, or nil when it is not bound
    /// or people still reach the steward through it.
    func disconnectProposal(_ entry: Entry, steward: String) -> CharterProposal? {
        guard let live = live[steward], case .object(var charter) = live.charter,
            isConnected(entry, steward: steward), disconnectBlocker(entry, steward: steward) == nil
        else { return nil }
        charter["bindings"] = .array(
            (live.charter["bindings"]?.array ?? []).filter { $0["id"]?.string != entry.id })
        return CharterProposal(
            steward: steward, baseVersion: live.version, charter: .object(charter),
            title: "Disconnect \(entry.id)",
            reason: "Stop reading from and acting in \(entry.id).")
    }

    static func connectReason(_ entry: Entry) -> String {
        var parts: [String] = []
        if !entry.read.isEmpty { parts.append("read " + entry.read.joined(separator: ", ")) }
        if !entry.actions.isEmpty {
            parts.append("propose " + entry.actions.map(\.kind).joined(separator: ", "))
        }
        guard !parts.isEmpty else { return "Connect \(entry.id)." }
        return "Let it " + parts.joined(separator: " and ") + " through \(entry.id)."
    }
}

/// A connection test's result in words.
enum ConnectionTestText {
    static func line(tools: [String], missing: [String]) -> String {
        let count = tools.count == 1 ? "1 tool" : "\(tools.count) tools"
        guard !missing.isEmpty else { return "Connected · \(count), every declared tool offered" }
        return "Connected · \(count), missing " + missing.joined(separator: ", ")
    }
}
