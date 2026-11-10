import AryaCore
import Foundation

/// The binding tool conventions (docs/PROTOCOL.md, "Binding conventions"): tool names and the
/// descriptors a binding server lists for them.
public enum BindingTools {
    public static let history = BindingHistory.tool
    public static let outcome = "outcome"
    public static let directory = "directory"
    public static let process = "process"
    public static let get = "get"
    public static let search = "search"

    /// The `tools/list` entry for a convention tool.
    public static func descriptor(_ name: String) -> JSONValue {
        let (description, properties, required): (String, [String: JSONValue], [String]) =
            switch name {
            case history:
                (
                    "Past records with what a person did with each, oldest first.",
                    [
                        "since": string, "until": string, "cursor": string,
                        "limit": ["type": "integer"],
                    ], []
                )
            case outcome:
                (
                    "The current state of what an executed action acted on.",
                    ["target": string, "action": string, "since": string], ["target"]
                )
            case directory:
                ("People who do this work and their roles.", ["role": string], [])
            case process: ("Queues, routing rules, and documents for this work.", [:], [])
            case get: ("One record by id.", ["id": string], ["id"])
            case search: ("Records whose content contains the query.", ["query": string], ["query"])
            default: ("", [:], [])
            }
        var schema: [String: JSONValue] = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return [
            "name": .string(name), "description": .string(description),
            "inputSchema": .object(schema),
        ]
    }

    private static let string: JSONValue = ["type": "string"]
}

/// Arguments of the `outcome` tool: what an executed action acted on, and optionally the action
/// kind and when it ran, so a binding can say what changed since.
public struct OutcomeCheckParams: Sendable, Hashable, Codable {
    public var target: String
    public var action: String?
    public var since: String?

    public init(target: String, action: String? = nil, since: String? = nil) {
        self.target = target
        self.action = action
        self.since = since
    }

    enum CodingKeys: String, CodingKey {
        case target, action, since
    }
}

/// Result of the `outcome` tool. `status` is `resolved`, `reopened`, `open`, or `unknown` (the
/// binding cannot tell); other words are kept as text.
public struct OutcomeCheckResult: Sendable, Hashable, Codable {
    public var target: String
    public var status: String
    public var at: String?
    public var note: String?
    public var metric: OutcomeMetric?

    public init(
        target: String, status: String, at: String? = nil, note: String? = nil,
        metric: OutcomeMetric? = nil
    ) {
        self.target = target
        self.status = status
        self.at = at
        self.note = note
        self.metric = metric
    }

    enum CodingKeys: String, CodingKey {
        case target, status, at, note, metric
    }
}

/// A number the outcome moved: its current `value` and, when known, the change since the
/// action (`delta`).
public struct OutcomeMetric: Sendable, Hashable, Codable {
    public var name: String
    public var value: Double
    public var delta: Double?
    public var unit: String?

    public init(name: String, value: Double, delta: Double? = nil, unit: String? = nil) {
        self.name = name
        self.value = value
        self.delta = delta
        self.unit = unit
    }

    enum CodingKeys: String, CodingKey {
        case name, value, delta, unit
    }
}

/// Arguments of the `directory` tool; `role` keeps only people with that role.
public struct DirectoryListParams: Sendable, Hashable, Codable {
    public var role: String?

    public init(role: String? = nil) { self.role = role }

    enum CodingKeys: String, CodingKey {
        case role
    }
}

/// Result of the `directory` tool.
public struct DirectoryListResult: Sendable, Hashable, Codable {
    public var people: [DirectoryPerson]

    public init(people: [DirectoryPerson]) { self.people = people }

    enum CodingKeys: String, CodingKey {
        case people
    }
}

/// A person who does this work: a contact id (`person:sam`), a display name, roles, and the
/// queues they handle.
public struct DirectoryPerson: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var roles: [String]
    public var queues: [String]

    public init(id: String, name: String, roles: [String] = [], queues: [String] = []) {
        self.id = id
        self.name = name
        self.roles = roles
        self.queues = queues
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        roles = try c.decodeIfPresent([String].self, forKey: .roles) ?? []
        queues = try c.decodeIfPresent([String].self, forKey: .queues) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case id, name, roles, queues
    }
}

/// Result of the `process` tool: how the work is organized today.
public struct ProcessListResult: Sendable, Hashable, Codable {
    public var queues: [ProcessQueue]
    public var rules: [RoutingRule]
    public var documents: [ProcessDocument]

    public init(
        queues: [ProcessQueue] = [], rules: [RoutingRule] = [], documents: [ProcessDocument] = []
    ) {
        self.queues = queues
        self.rules = rules
        self.documents = documents
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        queues = try c.decodeIfPresent([ProcessQueue].self, forKey: .queues) ?? []
        rules = try c.decodeIfPresent([RoutingRule].self, forKey: .rules) ?? []
        documents = try c.decodeIfPresent([ProcessDocument].self, forKey: .documents) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case queues, rules, documents
    }
}

/// A queue work is routed to, with the contact id of its owner.
public struct ProcessQueue: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var owner: String?
    public var description: String?

    public init(id: String, name: String, owner: String? = nil, description: String? = nil) {
        self.id = id
        self.name = name
        self.owner = owner
        self.description = description
    }

    enum CodingKeys: String, CodingKey {
        case id, name, owner, description
    }
}

/// A rule people follow today: `when` in plain words, `then` as an action.
public struct RoutingRule: Sendable, Hashable, Codable {
    public var id: String
    public var when: String
    public var then: HistoryAction
    /// Where the rule is written down, such as a document id.
    public var source: String?

    public init(id: String, when: String, then: HistoryAction, source: String? = nil) {
        self.id = id
        self.when = when
        self.then = then
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case id, when, then, source
    }
}

/// A document that describes the work, as plain text.
public struct ProcessDocument: Sendable, Hashable, Codable {
    public var id: String
    public var title: String
    public var text: String

    public init(id: String, title: String, text: String) {
        self.id = id
        self.title = title
        self.text = text
    }

    enum CodingKeys: String, CodingKey {
        case id, title, text
    }
}
