import Foundation

/// Where the CLI writes. Tests capture both streams; the entry point writes to stdout and stderr.
struct Output: Sendable {
    let write: @Sendable (String) -> Void
    let writeError: @Sendable (String) -> Void

    /// Standard output and standard error.
    static let standard = Output(
        write: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
        writeError: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })

    /// Encodes `value` as sorted, pretty-printed JSON with unescaped slashes.
    func json<T: Encodable>(_ value: T) throws(CLIError) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        do {
            write(String(decoding: try encoder.encode(value), as: UTF8.self))
        } catch {
            throw .failed("could not encode output: \(error)")
        }
    }
}

/// Left-aligned plain-text columns separated by two spaces, with an upper-case header.
struct Table: Sendable, Equatable {
    let headers: [String]
    var rows: [[String]] = []

    /// The rendered lines, without trailing spaces.
    var lines: [String] {
        let all = [headers.map { $0.uppercased() }] + rows
        var widths = Array(repeating: 0, count: headers.count)
        for row in all {
            for (column, cell) in row.enumerated() where column < widths.count {
                widths[column] = max(widths[column], cell.count)
            }
        }
        return all.map { row in
            row.enumerated()
                .map { column, cell in
                    column == row.count - 1
                        ? cell : cell.padding(toLength: widths[column], withPad: " ", startingAt: 0)
                }
                .joined(separator: "  ")
                .trimmingTrailingSpaces()
        }
    }
}

extension String {
    fileprivate func trimmingTrailingSpaces() -> String {
        String(reversed().drop { $0 == " " }.reversed())
    }
}

/// Plain-text renderings of the view models. One function per command keeps output easy to
/// find and test.
enum TextRender {
    static func initReport(_ report: InitReport) -> [String] {
        switch report.status {
        case .created: ["created arya home at \(report.home)"]
        case .existing: ["arya home already set up at \(report.home)"]
        }
    }

    static func stewards(_ stewards: [StewardSummary]) -> [String] {
        guard !stewards.isEmpty else {
            return ["no stewards yet; create one with `arya steward create`"]
        }
        var table = Table(headers: ["id", "name", "state", "version", "approvals", "last run"])
        for steward in stewards {
            table.rows.append([
                steward.id, steward.name, steward.state.rawValue, "\(steward.charterVersion)",
                "\(steward.pendingApprovals)", steward.lastRun ?? "-",
            ])
        }
        return table.lines
    }

    static func steward(_ detail: StewardDetail) -> [String] {
        let summary = detail.summary
        var lines = [
            "\(summary.id)  \(summary.name)",
            "state      \(summary.state.rawValue), charter v\(summary.charterVersion)",
            "outcome    \(detail.outcome)",
            "metric     \(detail.metric)",
            "adapter    \(detail.adapter), effort \(detail.effort)",
            "bindings   \(list(detail.bindings))",
            "triggers   \(list(detail.triggers))",
            "approvals  \(summary.pendingApprovals) pending",
            "last run   \(summary.lastRun ?? "-")",
        ]
        if !detail.guardrails.isEmpty {
            lines.append("guardrails")
            lines += detail.guardrails.map { "  - \($0)" }
        }
        return lines
    }

    static func run(_ report: RunReport) -> [String] {
        var lines = ["run \(report.run) (\(report.steward)) \(report.status)"]
        if !report.summary.isEmpty { lines.append("summary: \(report.summary)") }
        lines += report.decisions.map { "decision: \($0)" }
        for action in report.actions {
            var line = "action \(action.id): \(action.kind) \(action.target) -> "
            line += action.disposition.rawValue
            if let approval = action.approval { line += " (approval \(approval))" }
            lines.append(line)
        }
        return lines
    }

    static func approvals(_ approvals: [ApprovalSummary]) -> [String] {
        guard !approvals.isEmpty else { return ["no approvals waiting"] }
        var table = Table(headers: ["id", "steward", "action", "target", "state", "requested"])
        for approval in approvals {
            table.rows.append([
                approval.id, approval.steward, approval.action, approval.target,
                approval.state.rawValue, approval.requestedAt,
            ])
        }
        return table.lines
    }

    static func decision(_ approval: ApprovalSummary) -> [String] {
        ["\(approval.id) \(approval.state.rawValue): \(approval.action) \(approval.target)"]
    }

    static func events(_ events: [EventSummary]) -> [String] {
        guard !events.isEmpty else { return ["the ledger is empty"] }
        var table = Table(headers: ["seq", "at", "type", "actor", "steward", "run"])
        for event in events {
            table.rows.append([
                "\(event.seq)", event.at, event.type, event.actor, event.steward ?? "-",
                event.run ?? "-",
            ])
        }
        return table.lines
    }

    static func verify(_ report: VerifyReport) -> [String] {
        let counts = "\(report.events) events in \(report.segments) segment(s)"
        if report.isValid { return ["ledger ok: \(counts)"] }
        guard let firstBreak = report.firstBreak else { return ["ledger broken (\(counts))"] }
        return ["ledger broken at seq \(firstBreak.seq): \(firstBreak.reason) (\(counts))"]
    }

    private static func list(_ items: [String]) -> String {
        items.isEmpty ? "-" : items.joined(separator: ", ")
    }
}
