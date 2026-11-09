import Foundation

/// The single source of time, generated ids, and randomness for library code (decision 0006).
///
/// - `live` reads the system clock and the system random generator.
/// - `fixed(start:stepMillis:seed:)` is deterministic: each `now()` advances the clock by
///   `stepMillis`, and ids and random numbers come from a seeded generator. Two `fixed`
///   ambients with the same arguments produce identical sequences.
/// - `recorded(_:)` serves readings captured from an earlier run, in order, for replay. A
///   reading of the wrong kind, or one past the end, is noted in `mismatches` and answered
///   from a `fixed` fallback so replay can report a divergence instead of crashing.
///
/// Every reading is also appended to a log that `drainReadings()` returns, so callers can
/// record readings an event envelope does not already carry (`env.read`).
public final class Ambient: Sendable {
    private let state: Locked<State>

    private init(_ source: Source) {
        state = Locked(State(source: source))
    }

    /// The real clock and system randomness. Only entry points should create it.
    public static var live: Ambient { Ambient(.live) }

    /// A deterministic ambient for tests and rehearsal.
    public static func fixed(
        start: Timestamp = Timestamp(millis: 1_767_225_600_000), stepMillis: Int64 = 1,
        seed: UInt64 = 0
    ) -> Ambient {
        Ambient(.fixed(Fixed(now: start.millis, step: stepMillis, rng: SeededGenerator(seed))))
    }

    /// Serves `readings` in order; see the type documentation.
    public static func recorded(_ readings: [AmbientReading]) -> Ambient {
        let first = readings.lazy.compactMap(\.time).first ?? Timestamp(millis: 0)
        let fallback = Fixed(now: first.millis, step: 1, rng: SeededGenerator(0))
        return Ambient(.recorded(readings[...], fallback))
    }

    /// The current time.
    public func now() -> Timestamp {
        state.withLock { $0.now() }
    }

    /// A new id of type `ID`: the prefix followed by a 26-character ULID body.
    public func newID<ID: PrefixedID>(_ type: ID.Type = ID.self) -> ID {
        state.withLock { $0.newID(type) }
    }

    /// 64 random bits.
    public func nextRandom() -> UInt64 {
        state.withLock { $0.nextRandom() }
    }

    /// A uniformly distributed integer in `range`, which must not be empty.
    public func random(in range: Range<Int>) -> Int {
        precondition(!range.isEmpty, "empty range")
        var generator = AmbientGenerator(ambient: self)
        return Int.random(in: range, using: &generator)
    }

    /// Readings made since the last call, in order.
    public func drainReadings() -> [AmbientReading] {
        state.withLock { state in
            defer { state.log.removeAll() }
            return state.log
        }
    }

    /// Replay problems seen by a `recorded` ambient, in order. Always empty otherwise.
    public var mismatches: [String] { state.withLock { $0.mismatches } }

    /// Whether a `recorded` ambient has served every reading. Always true otherwise.
    public var isExhausted: Bool {
        state.withLock { state in
            if case .recorded(let rest, _) = state.source { return rest.isEmpty }
            return true
        }
    }
}

/// One value an `Ambient` produced. Encoded as `{"kind":"time","value":"…"}`,
/// `{"kind":"id","value":"run_…"}`, or `{"kind":"random","value":123}`.
public enum AmbientReading: Hashable, Sendable, Codable {
    case time(Timestamp)
    case id(String)
    case random(UInt64)

    var time: Timestamp? {
        if case .time(let value) = self { return value }
        return nil
    }

    private enum CodingKeys: String, CodingKey { case kind, value }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "time": self = .time(try container.decode(Timestamp.self, forKey: .value))
        case "id": self = .id(try container.decode(String.self, forKey: .value))
        case "random": self = .random(try container.decode(UInt64.self, forKey: .value))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "unknown reading \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .time(let value):
            try container.encode("time", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .id(let value):
            try container.encode("id", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .random(let value):
            try container.encode("random", forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

/// SplitMix64: a small, fast, seedable generator. Not cryptographic.
public struct SeededGenerator: RandomNumberGenerator, Sendable, Hashable {
    private var state: UInt64

    public init(_ seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A `RandomNumberGenerator` view of an ambient, for standard library APIs such as
/// `shuffled(using:)`.
public struct AmbientGenerator: RandomNumberGenerator {
    public let ambient: Ambient
    public init(ambient: Ambient) { self.ambient = ambient }
    public mutating func next() -> UInt64 { ambient.nextRandom() }
}

/// ULID bodies: 48 bits of milliseconds and 80 random bits in Crockford base32.
public enum ULID {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)

    /// Encodes `millis` (low 48 bits) and `random` (low 80 bits of `hi:lo`) as 26 characters.
    public static func encode(millis: Int64, randomHigh: UInt16, randomLow: UInt64) -> String {
        let time = UInt64(bitPattern: millis) & 0xFFFF_FFFF_FFFF
        // 128 bits as hi:lo, then 26 groups of 5 bits from the top of a 130-bit field.
        let hi = time << 16 | UInt64(randomHigh)
        let lo = randomLow
        var out = [UInt8]()
        out.reserveCapacity(26)
        for index in 0..<26 {
            let shift = 125 - 5 * index
            out.append(alphabet[Int(bits(hi: hi, lo: lo, shift: shift))])
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func bits(hi: UInt64, lo: UInt64, shift: Int) -> UInt64 {
        if shift >= 64 { return (hi >> UInt64(shift - 64)) & 31 }
        if shift > 59 {
            let fromHi = hi << UInt64(64 - shift)
            return (fromHi | lo >> UInt64(shift)) & 31
        }
        return (lo >> UInt64(shift)) & 31
    }
}

// MARK: - State

private struct Fixed: Sendable {
    var now: Int64
    var step: Int64
    var rng: SeededGenerator
}

private enum Source: Sendable {
    case live
    case fixed(Fixed)
    case recorded(ArraySlice<AmbientReading>, Fixed)
}

private struct State: Sendable {
    var source: Source
    var log: [AmbientReading] = []
    var mismatches: [String] = []
    var lastMillis: Int64 = 0

    mutating func now() -> Timestamp {
        let value: Timestamp
        switch source {
        case .live:
            value = Timestamp(millis: Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)))
        case .fixed(var fixed):
            value = Timestamp(millis: fixed.now)
            fixed.now += fixed.step
            source = .fixed(fixed)
        case .recorded:
            if case .time(let recorded)? = pop(expecting: "time") {
                value = recorded
            } else if case .recorded(let rest, var fallback) = source {
                value = Timestamp(millis: fallback.now)
                fallback.now += fallback.step
                source = .recorded(rest, fallback)
            } else {
                value = Timestamp(millis: lastMillis)
            }
        }
        lastMillis = value.millis
        log.append(.time(value))
        return value
    }

    mutating func newID<ID: PrefixedID>(_ type: ID.Type) -> ID {
        if case .recorded = source {
            if case .id(let raw)? = pop(expecting: "id"), let id = ID(rawValue: raw) {
                log.append(.id(raw))
                return id
            }
        }
        let high = UInt16(truncatingIfNeeded: randomBits())
        let low = randomBits()
        let id = ID(
            unchecked: ID.prefix
                + ULID.encode(
                    millis: idMillis(), randomHigh: high,
                    randomLow: low))
        log.append(.id(id.rawValue))
        return id
    }

    mutating func nextRandom() -> UInt64 {
        if case .recorded = source, case .random(let value)? = pop(expecting: "random") {
            log.append(.random(value))
            return value
        }
        let value = randomBits()
        log.append(.random(value))
        return value
    }

    private mutating func idMillis() -> Int64 {
        if case .live = source {
            return Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
        }
        return lastMillis
    }

    private mutating func randomBits() -> UInt64 {
        switch source {
        case .live:
            var system = SystemRandomNumberGenerator()
            return system.next()
        case .fixed(var fixed):
            defer { source = .fixed(fixed) }
            return fixed.rng.next()
        case .recorded(let rest, var fallback):
            defer { source = .recorded(rest, fallback) }
            return fallback.rng.next()
        }
    }

    private mutating func pop(expecting kind: String) -> AmbientReading? {
        guard case .recorded(var rest, let fallback) = source else { return nil }
        guard let next = rest.popFirst() else {
            mismatches.append("reading \(log.count + 1): wanted \(kind), recording ended")
            return nil
        }
        source = .recorded(rest, fallback)
        let matches: Bool
        switch (next, kind) {
        case (.time, "time"), (.id, "id"), (.random, "random"): matches = true
        default: matches = false
        }
        if !matches {
            mismatches.append("reading \(log.count + 1): wanted \(kind), recorded \(next)")
            return nil
        }
        return next
    }
}

/// A value guarded by a lock. `Synchronization.Mutex` needs macOS 15; this needs 14.
public final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ value: Value) { self.value = value }

    public func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
