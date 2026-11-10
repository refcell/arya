import AryaCore
import Foundation

/// `system.retention.set`: how many days of history to keep for one steward, or the home
/// default when `steward` is nil; nil `days` clears the setting. Actor: the person.
public struct SystemRetentionSet: EventPayload {
    public static let type = EventType.systemRetentionSet
    public var steward: StewardID?
    public var days: Int?

    public init(steward: StewardID? = nil, days: Int? = nil) {
        self.steward = steward
        self.days = days
    }

    enum CodingKeys: String, CodingKey { case steward, days }
}

/// The retention settings the ledger records, latest per steward wins.
public struct RetentionPolicy: LedgerProjection, Hashable {
    /// Days for events with no steward and for stewards with no setting of their own.
    public var defaultDays: Int?
    /// Per-steward days.
    public var stewards: [StewardID: Int] = [:]

    public init() {}

    public mutating func apply(_ event: Event) throws {
        guard event.type == .systemRetentionSet else { return }
        let body = try event.payload(as: SystemRetentionSet.self)
        if let steward = body.steward {
            stewards[steward] = body.days
        } else {
            defaultDays = body.days
        }
    }

    /// The days that apply to an event of `steward` (its own setting, else the default).
    public func days(for steward: StewardID?) -> Int? {
        steward.flatMap { stewards[$0] } ?? defaultDays
    }

    /// Reads the settings from the ledger.
    public static func read(_ reader: LedgerReader) throws -> RetentionPolicy {
        var policy = RetentionPolicy()
        try reader.forEach(LedgerFilter(types: [.systemRetentionSet])) { try policy.apply($0) }
        return policy
    }
}

/// What retention would move to `archive/` now: the longest run of closed segments, oldest
/// first, in which every event is older than the days that apply to it. A segment holding one
/// event that must be kept (no setting, or too recent) ends the run, because compaction moves
/// whole segments and the chain must stay contiguous.
public struct RetentionPlan: Hashable, Sendable {
    /// Eligible segment names, oldest first.
    public var segments: [String]
    /// The last eligible `seq` (0 when nothing is eligible).
    public var through: Int64
    /// Eligible events by steward id (`""` for events with no steward).
    public var events: [String: Int]
    /// Total bytes of the eligible segments.
    public var bytes: Int64

    /// Computes the plan at `now`.
    public static func compute(
        _ reader: LedgerReader, policy: RetentionPolicy, now: Timestamp
    ) throws -> RetentionPlan {
        var plan = RetentionPlan(segments: [], through: 0, events: [:], bytes: 0)
        guard policy.defaultDays != nil || !policy.stewards.isEmpty else { return plan }
        for segment in try reader.existingSegments().dropLast() {
            var counts: [String: Int] = [:]
            var last: Int64 = 0
            var keep = false
            try reader.scan(segment) { event, _, _ in
                guard !keep else { return }
                guard let days = policy.days(for: event.steward),
                    event.at.millis < now.millis - Int64(days) * 86_400_000
                else {
                    keep = true
                    return
                }
                counts[event.steward?.rawValue ?? "", default: 0] += 1
                last = event.seq
            }
            if keep { break }
            plan.segments.append(segment.name)
            plan.through = last
            plan.events.merge(counts, uniquingKeysWith: +)
            let attributes = try? FileManager.default.attributesOfItem(atPath: segment.url.path)
            plan.bytes += (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
        return plan
    }
}
