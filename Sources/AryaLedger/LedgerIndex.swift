import AryaCore

/// A small, ledger-owned projection: event counts, and where each steward's and run's events
/// are. The facade uses it to page the ledger table and to find a run's events without a
/// full scan of every payload.
public struct LedgerIndex: LedgerProjection, Hashable, Codable {
    /// Where a run's events are.
    public struct RunSpan: Hashable, Sendable, Codable {
        public var steward: StewardID?
        public var firstSeq: Int64
        public var lastSeq: Int64
        public var events: Int
        public var startedAt: Timestamp
        public var lastAt: Timestamp

        enum CodingKeys: String, CodingKey {
            case steward, firstSeq, lastSeq, events, startedAt, lastAt
        }
    }

    /// Where a steward's events are.
    public struct StewardSpan: Hashable, Sendable, Codable {
        public var firstSeq: Int64
        public var lastSeq: Int64
        public var firstAt: Timestamp
        public var lastAt: Timestamp

        enum CodingKeys: String, CodingKey { case firstSeq, lastSeq, firstAt, lastAt }
    }

    public private(set) var events: Int64 = 0
    public private(set) var countsByType: [EventType: Int] = [:]
    public private(set) var eventsBySteward: [StewardID: Int] = [:]
    public private(set) var runs: [RunID: RunSpan] = [:]
    public private(set) var stewards: [StewardID: StewardSpan] = [:]
    public private(set) var firstAt: Timestamp?
    public private(set) var lastAt: Timestamp?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case events, countsByType, eventsBySteward, runs, stewards, firstAt, lastAt
    }

    public mutating func apply(_ event: Event) throws {
        events += 1
        countsByType[event.type, default: 0] += 1
        if let steward = event.steward {
            eventsBySteward[steward, default: 0] += 1
            if var span = stewards[steward] {
                span.lastSeq = event.seq
                span.lastAt = event.at
                stewards[steward] = span
            } else {
                stewards[steward] = StewardSpan(
                    firstSeq: event.seq, lastSeq: event.seq, firstAt: event.at, lastAt: event.at)
            }
        }
        if let run = event.run {
            if var span = runs[run] {
                span.lastSeq = event.seq
                span.events += 1
                span.lastAt = event.at
                if span.steward == nil { span.steward = event.steward }
                runs[run] = span
            } else {
                runs[run] = RunSpan(
                    steward: event.steward, firstSeq: event.seq, lastSeq: event.seq, events: 1,
                    startedAt: event.at, lastAt: event.at)
            }
        }
        if firstAt == nil { firstAt = event.at }
        lastAt = event.at
    }

    /// Runs of `steward`, oldest first.
    public func runs(of steward: StewardID) -> [(RunID, RunSpan)] {
        runs.filter { $0.value.steward == steward }.sorted { $0.value.firstSeq < $1.value.firstSeq }
            .map { ($0.key, $0.value) }
    }

    /// The lowest `seq` an event matching `filter` can have, judged by its run and steward
    /// spans, given that this index covers events through `coveredSeq`. A run or steward the
    /// index has not seen can only appear after `coveredSeq`. 1 when the filter names neither.
    public func firstPossibleSeq(_ filter: LedgerFilter, coveredSeq: Int64) -> Int64 {
        var start: Int64 = 1
        if let run = filter.run { start = max(start, runs[run]?.firstSeq ?? coveredSeq + 1) }
        if let steward = filter.steward {
            start = max(start, stewards[steward]?.firstSeq ?? coveredSeq + 1)
        }
        return start
    }
}
