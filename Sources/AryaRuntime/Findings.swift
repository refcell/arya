import AryaAdapters
import AryaCore
import AryaLedger
import Foundation

// Proactive findings (decision 0055). A live run, typically a scheduled wake, may return
// findings: a problem or an opportunity it noticed beyond its input, with evidence, an optional
// suggested action, and whether a person must decide. Each well-formed one is recorded as
// `finding.raised` on the run (actor: the steward) unless the steward already has an open
// finding with the same title, so a daily wake does not repeat itself. A finding stays open
// until a person resolves it (`finding.resolved`: acted on or dismissed). Open findings feed the
// Overview, and those that need a person feed Needs you. A suggestion is shown, not executed:
// a steward acts through the actions it proposes, under policy.

/// Event types of findings.
public enum FindingEventType {
    /// `finding.raised`.
    public static let raised = EventType("finding.raised")
    /// `finding.resolved`.
    public static let resolved = EventType("finding.resolved")
}

/// Limits and helpers for findings.
public enum Findings {
    public static let kinds: Set<String> = ["problem", "opportunity"]
    public static let titleLimit = 140
    public static let evidenceLimit = 5
    public static let evidenceLineLimit = 280

    /// The comparison form of a title: trimmed, lowercased, inner spaces collapsed.
    public static func key(_ title: String) -> String {
        title.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// `finding.raised` (actor: the steward; run: the run that noticed it).
public struct FindingRaised: Sendable, Hashable, Codable {
    /// The finding's id within its run.
    public var finding: String
    /// `problem` or `opportunity`.
    public var kind: String
    public var title: String
    public var evidence: [String]
    public var suggestion: ProposedAction?
    public var needsPerson: Bool

    public init(
        finding: String, kind: String, title: String, evidence: [String] = [],
        suggestion: ProposedAction? = nil, needsPerson: Bool = false
    ) {
        self.finding = finding
        self.kind = kind
        self.title = title
        self.evidence = evidence
        self.suggestion = suggestion
        self.needsPerson = needsPerson
    }

    /// The record for an adapter's finding, or nil when it is malformed: an empty id or title,
    /// or a kind other than `problem` or `opportunity`. The title is cut to 140 characters and
    /// the evidence to 5 non-empty lines of at most 280.
    public init?(_ finding: RunResult.Finding) {
        let kind = finding.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let title = finding.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = finding.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Findings.kinds.contains(kind), !title.isEmpty, !id.isEmpty else { return nil }
        let evidence = finding.evidence
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(Findings.evidenceLimit)
            .map { String($0.prefix(Findings.evidenceLineLimit)) }
        self.init(
            finding: id, kind: kind, title: String(title.prefix(Findings.titleLimit)),
            evidence: evidence, suggestion: finding.suggestion.map(ProposedAction.init),
            needsPerson: finding.needsPerson ?? false)
    }
}

/// `finding.resolved` (actor: the person).
public struct FindingResolved: Sendable, Hashable, Codable {
    public var finding: String
    /// `acted` or `dismissed`.
    public var resolution: String
    public var note: String?

    public init(finding: String, resolution: String, note: String? = nil) {
        self.finding = finding
        self.resolution = resolution
        self.note = note
    }
}

/// One finding as it stands.
public struct FindingRecord: Sendable, Hashable {
    public var steward: StewardID
    public var run: RunID
    public var raised: FindingRaised
    public var raisedAt: Timestamp
    public var resolution: String?
    public var resolvedBy: RuntimeActor?

    public var title: String { raised.title }
    public var isOpen: Bool { resolution == nil }
}

/// Findings projected from the ledger, in the order they were raised.
public struct FindingBook: Sendable {
    public private(set) var all: [FindingRecord] = []
    private var index: [String: Int] = [:]

    /// An empty book.
    public init() {}

    public init(_ events: [RuntimeEvent]) throws {
        for event in events { try apply(event) }
    }

    /// Folds one event.
    public mutating func apply(_ event: RuntimeEvent) throws {
        guard let run = event.draft.run, let steward = event.draft.steward else { return }
        switch event.type {
        case FindingEventType.raised.rawValue:
            let body = try Payload.decode(FindingRaised.self, event.payload)
            index[Self.key(run, body.finding)] = all.count
            all.append(FindingRecord(steward: steward, run: run, raised: body, raisedAt: event.at))
        case FindingEventType.resolved.rawValue:
            let body = try Payload.decode(FindingResolved.self, event.payload)
            guard let at = index[Self.key(run, body.finding)], all[at].isOpen else { return }
            all[at].resolution = body.resolution
            all[at].resolvedBy = event.draft.actor
        default:
            return
        }
    }

    /// `steward`'s open findings, oldest first.
    public func open(_ steward: StewardID) -> [FindingRecord] {
        all.filter { $0.steward == steward && $0.isOpen }
    }

    static func key(_ run: RunID, _ finding: String) -> String { run.rawValue + "/" + finding }
}

/// Why a finding could not be resolved.
public enum FindingError: Error, Equatable, Sendable {
    case notFound(String)
    case alreadyResolved(String)
    case invalidResolution(String)
}

extension FindingBook {
    /// Records that `actor` resolved finding `finding` of `run` (`acted` or `dismissed`).
    public static func resolve(
        _ finding: String, run: RunID, resolution: String, note: String? = nil,
        by actor: RuntimeActor, sink: any EventSink
    ) async throws {
        guard ["acted", "dismissed"].contains(resolution) else {
            throw FindingError.invalidResolution(resolution)
        }
        let book = try FindingBook(try await sink.events(from: 1))
        guard let record = book.all.first(where: { $0.run == run && $0.raised.finding == finding })
        else { throw FindingError.notFound(finding) }
        guard record.isOpen else { throw FindingError.alreadyResolved(finding) }
        _ = try await sink.append(
            RuntimeEventDraft(
                type: FindingEventType.resolved.rawValue, steward: record.steward, run: run,
                actor: actor,
                payload: try Payload.encode(
                    FindingResolved(finding: finding, resolution: resolution, note: note))))
    }
}
