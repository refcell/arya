import AryaCore
import Foundation

/// A binding over a local directory of exported records (docs/PROTOCOL.md, "Folder binding").
/// It serves the convention tools from whichever of these files exist, read again on every
/// call so edits show up without a restart:
///
/// - `history.json` (an array, or `{"history":[…]}`), `history.jsonl`, or `history.csv`
/// - `outcomes.json`, `outcomes.jsonl`, or `outcomes.csv`
/// - `directory.json`, `directory.jsonl`, or `directory.csv`
/// - `process.json`
///
/// In `history.csv`, columns `id`, `at`, `input`, `choice`, `outcome`, `outcome_at`,
/// `outcome_note`, `target`, `by`, and `acted_at` have their convention meaning, a column named
/// `action.<kind>.<param>` adds that param to an action of that kind, and every other column
/// is part of the record (`get`, `search`).
public struct FolderBindingSource: BindingSource {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var serverName: String { "arya-folder-binding" }

    public func tools() throws -> [JSONValue] {
        try load().toolNames.map(BindingTools.descriptor)
    }

    public func call(_ tool: String, _ arguments: JSONValue) throws -> JSONValue {
        try load().call(tool, arguments)
    }

    // MARK: Loading

    func load() throws -> RecordSet {
        RecordSet(
            history: try rows("history", HistoryItem.self, csv: Self.historyItem) ?? [],
            outcomes: try rows("outcomes", OutcomeCheckResult.self, csv: Self.outcome) ?? [],
            directory: try rows("directory", DirectoryPerson.self, csv: Self.person),
            process: try file("process.json").map { data in
                try decode(ProcessListResult.self, data, "process.json")
            })
    }

    /// The rows of `<name>.json`, `.jsonl`, or `.csv`, the first that exists; nil when none
    /// does.
    private func rows<T: Decodable>(
        _ name: String, _ type: T.Type, csv: ([String: String], [String]) throws -> T?
    ) throws -> [T]? {
        if let data = try file("\(name).json") {
            let value = try decode(JSONValue.self, data, "\(name).json")
            let list = value.arrayValue ?? value[name]?.arrayValue ?? []
            return try list.map { try $0.decode(T.self) }
        }
        if let data = try file("\(name).jsonl") {
            return try String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
                .enumerated().map { index, line in
                    try decode(T.self, Data(line.utf8), "\(name).jsonl line \(index + 1)")
                }
        }
        if let data = try file("\(name).csv") {
            let text = String(decoding: data, as: UTF8.self)
            let header = CSV.header(text)
            return try CSV.records(text).compactMap { try csv($0, header) }
        }
        return nil
    }

    private func file(_ name: String) throws -> Data? {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw BindingToolError("cannot read \(name): \(error.localizedDescription)")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data, _ name: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw BindingToolError("\(name) is not valid: \(error)")
        }
    }

    // MARK: CSV rows

    static let historyColumns: Set = [
        "id", "at", "input", "choice", "outcome", "outcome_at", "outcome_note", "target", "by",
        "acted_at",
    ]

    static func historyItem(_ row: [String: String], _ header: [String]) -> HistoryItem? {
        guard let id = row["id"], let at = row["at"] else { return nil }
        var record: [String: JSONValue] = ["id": .string(id)]
        var actions: [(kind: String, params: [String: JSONValue])] = []
        for column in header {
            guard let value = row[column] else { continue }
            let parts = column.split(separator: ".", maxSplits: 2).map(String.init)
            if parts.count == 3, parts[0] == "action" {
                if let index = actions.firstIndex(where: { $0.kind == parts[1] }) {
                    actions[index].params[parts[2]] = .string(value)
                } else {
                    actions.append((parts[1], [parts[2]: .string(value)]))
                }
            } else if !historyColumns.contains(column) {
                record[column] = .string(value)
            }
        }
        let subject = row["subject"] ?? row["title"]
        return HistoryItem(
            id: id, at: at,
            input: row["input"] ?? "New record \(id)" + (subject.map { ": \($0)" } ?? ""),
            record: .object(record),
            actions: actions.map { action in
                HistoryAction(
                    kind: action.kind, target: row["target"], params: .object(action.params),
                    by: row["by"], at: row["acted_at"])
            },
            choice: row["choice"],
            outcome: row["outcome"].map {
                HistoryOutcome(status: $0, at: row["outcome_at"], note: row["outcome_note"])
            })
    }

    static func outcome(_ row: [String: String], _ header: [String]) -> OutcomeCheckResult? {
        guard let target = row["target"], let status = row["status"] else { return nil }
        let metric = row["metric"].flatMap { name in
            row["value"].flatMap(Double.init).map { value in
                OutcomeMetric(
                    name: name, value: value, delta: row["delta"].flatMap(Double.init),
                    unit: row["unit"])
            }
        }
        return OutcomeCheckResult(
            target: target, status: status, at: row["at"], note: row["note"], metric: metric)
    }

    static func person(_ row: [String: String], _ header: [String]) -> DirectoryPerson? {
        guard let id = row["id"], let name = row["name"] else { return nil }
        func list(_ column: String) -> [String] {
            (row[column] ?? "").split(separator: ";").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
        }
        return DirectoryPerson(id: id, name: name, roles: list("roles"), queues: list("queues"))
    }
}
