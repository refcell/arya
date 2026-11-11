import Arya
import Foundation

/// A steward's periodic report as its live charter sets it (`report`: who, cadence, weekday,
/// UTC hour) and when it last went out (`report.sent`). Setting or stopping it is a gated
/// charter proposal, like every other People edit.
struct PeopleReport: Hashable, Sendable {
    var steward: String
    var live: LiveCharter?
    /// Person binding ids it goes to; empty when no report is set.
    var to: [String]
    /// `weekly` or `daily`; nil when no report is set.
    var cadence: String?
    /// ISO weekday, 1 is Monday.
    var weekday: Int
    /// UTC hour.
    var hour: Int
    /// The last `report.sent` time and its text.
    var lastSent: Date?
    var lastText: String?

    var configured: Bool { cadence != nil }

    init(events: [FeatureEvent], steward: String) {
        self.steward = steward
        live = LiveCharter.find(events: events, steward: steward)
        let report = live?.charter["report"]
        to = report?["to"]?.array?.compactMap(\.string) ?? []
        cadence = report?["cadence"]?.string
        weekday = report?["weekday"]?.number.map { Int($0) } ?? 1
        hour = report?["hour"]?.number.map { Int($0) } ?? 9
        let sent = events.last { $0.steward == steward && $0.type == "report.sent" }
        lastSent = sent?.at
        lastText = sent?.payload["text"]?.string
    }

    /// "Weekly on Mondays at 09:00 UTC to Sam".
    func schedule(names: (String) -> String) -> String {
        guard let cadence else { return "No report set." }
        let when =
            cadence == "daily"
            ? "Daily at \(Self.hour(hour))"
            : "Weekly on \(Self.days[(weekday - 1 + 7) % 7])s at \(Self.hour(hour))"
        let who = to.isEmpty ? "no one" : to.map(names).joined(separator: ", ")
        return "\(when) to \(who)."
    }

    /// The next moment it goes out after `now` (the runtime's slot rule: the UTC hour, on the
    /// weekday for weekly reports); nil when no report is set.
    func next(after now: Date) -> Date? {
        guard let cadence else { return nil }
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        var slot = calendar.startOfDay(for: now).addingTimeInterval(Double(hour) * 3600)
        if slot <= now { slot = slot.addingTimeInterval(86_400) }
        guard cadence == "weekly" else { return slot }
        for _ in 0..<7 {
            // Calendar's 1 is Sunday; ISO's 1 is Monday.
            if (calendar.component(.weekday, from: slot) + 5) % 7 + 1 == weekday { return slot }
            slot = slot.addingTimeInterval(86_400)
        }
        return slot
    }

    static let days = [
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
    ]

    static func hour(_ hour: Int) -> String { String(format: "%02d:00 UTC", hour) }

    /// A proposal setting the report to `draft`.
    func proposal(_ draft: ReportDraft) -> CharterProposal? {
        guard let live, case .object(var charter) = live.charter, draft.issues.isEmpty else {
            return nil
        }
        var report: [String: FeatureJSON] = [
            "to": .array(draft.to.map(FeatureJSON.string)), "cadence": .string(draft.cadence),
        ]
        if draft.cadence == "weekly", draft.weekday != 1 {
            report["weekday"] = .number(Double(draft.weekday))
        }
        if let hour = draft.hourValue, hour != 9 { report["hour"] = .number(Double(hour)) }
        charter["report"] = .object(report)
        let verb = configured ? "Change" : "Send"
        return CharterProposal(
            steward: steward, baseVersion: live.version, charter: .object(charter),
            title: "\(verb) a \(draft.cadence) report",
            reason: "People hear how the outcome is going without opening the app.")
    }

    /// A proposal that stops the report.
    func stopProposal() -> CharterProposal? {
        guard let live, configured, case .object(var charter) = live.charter else { return nil }
        charter["report"] = nil
        return CharterProposal(
            steward: steward, baseVersion: live.version, charter: .object(charter),
            title: "Stop the \(cadence ?? "") report", reason: "No longer needed.")
    }
}

/// The report form's answers.
struct ReportDraft: Hashable, Sendable {
    var cadence = "weekly"
    /// Person binding ids, in the directory's order.
    var to: [String] = []
    var weekday = 1
    var hour = "9"

    init() {}

    init(_ report: PeopleReport) {
        cadence = report.cadence ?? "weekly"
        to = report.to
        weekday = report.weekday
        hour = String(report.hour)
    }

    var hourValue: Int? { Int(hour.trimmingCharacters(in: .whitespaces)) }

    mutating func toggle(_ person: String, order: [String]) {
        if to.contains(person) {
            to.removeAll { $0 == person }
        } else {
            to = order.filter { to.contains($0) || $0 == person }
        }
    }

    var issues: [String] {
        var out: [String] = []
        if to.isEmpty { out.append("Choose who gets the report.") }
        if !(0...23).contains(hourValue ?? -1) { out.append("Give an hour from 0 to 23 (UTC).") }
        return out
    }
}

/// Report previews for this session, keyed by steward, read from the workspace.
@MainActor
final class ReportDigestStore: ObservableObject {
    @Published var digests: [String: ReportDigest] = [:]
    @Published var problems: [String: String] = [:]

    func load(
        _ steward: String,
        read: @escaping @Sendable (String) async throws -> ReportDigest
    ) {
        Task {
            do {
                digests[steward] = try await read(steward)
                problems[steward] = nil
            } catch {
                problems[steward] = Self.text(error)
            }
        }
    }

    /// The error in a sentence, cause first.
    nonisolated static func text(_ error: any Error) -> String {
        if case .unavailable(let what)? = error as? FeatureReadError {
            return "This workspace cannot read \(what) yet."
        }
        if let error = error as? WorkspaceError { return error.description }
        return error.localizedDescription
    }
}

/// Report text as a person reads it: refs as names and snake-case keys ("routed_within_1h",
/// a metric) in words, for reports stored before the runtime wrote words itself.
enum PeopleReportText {
    private static let key = try? NSRegularExpression(
        pattern: #"\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\b"#)

    static func prose(_ text: String) -> String {
        let named = HumanText.sentence(text)
        guard let key, named.contains("_") else { return named }
        var result = named
        let range = NSRange(named.startIndex..., in: named)
        for match in key.matches(in: named, range: range).reversed() {
            guard let whole = Range(match.range, in: result) else { continue }
            result.replaceSubrange(
                whole, with: StewardPulseView.metricWords(String(result[whole])))
        }
        return result
    }
}
