/// A point in time with millisecond precision, encoded as an RFC 3339 UTC string with exactly
/// three fractional digits: `2026-01-01T12:00:00.000Z`. Library code gets timestamps from
/// `Ambient`, never from the system clock.
public struct Timestamp: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    /// Milliseconds since 1970-01-01T00:00:00Z.
    public var millis: Int64

    public init(millis: Int64) { self.millis = millis }

    /// Parses `YYYY-MM-DDTHH:MM:SS[.fff]Z`. Fractions longer than three digits are truncated.
    public init?(_ text: String) {
        guard let parsed = TimestampFormat.parse(Array(text.utf8)) else { return nil }
        millis = parsed
    }

    /// Adds `milliseconds`.
    public func adding(milliseconds: Int64) -> Timestamp {
        Timestamp(millis: millis + milliseconds)
    }

    public var description: String { TimestampFormat.format(millis) }

    public static func < (lhs: Timestamp, rhs: Timestamp) -> Bool { lhs.millis < rhs.millis }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let value = Timestamp(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "bad time")
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Proleptic Gregorian calendar arithmetic (days from civil, after H. Hinnant), so formatting
/// never depends on locale, time zone, or Foundation formatter behavior.
enum TimestampFormat {
    static let msPerDay: Int64 = 86_400_000

    static func format(_ millis: Int64) -> String {
        let days = floorDiv(millis, msPerDay)
        let inDay = millis - days * msPerDay
        let (year, month, day) = civil(fromDays: days)
        let hour = inDay / 3_600_000
        let minute = inDay / 60_000 % 60
        let second = inDay / 1000 % 60
        let milli = inDay % 1000
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))T\(pad(hour, 2)):"
            + "\(pad(minute, 2)):\(pad(second, 2)).\(pad(milli, 3))Z"
    }

    static func parse(_ b: [UInt8]) -> Int64? {
        guard b.count >= 20, b.last == UInt8(ascii: "Z") else { return nil }
        let seps: [(Int, Character)] = [(4, "-"), (7, "-"), (10, "T"), (13, ":"), (16, ":")]
        for (index, char) in seps where b[index] != char.asciiValue { return nil }
        guard let year = digits(b, 0, 4), let month = digits(b, 5, 2), let day = digits(b, 8, 2),
            let hour = digits(b, 11, 2), let minute = digits(b, 14, 2),
            let second = digits(b, 17, 2)
        else { return nil }
        var milli: Int64 = 0
        if b.count > 20 {
            guard b[19] == UInt8(ascii: "."), b.count > 21 else { return nil }
            let fraction = b[20..<(b.count - 1)]
            guard fraction.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
            for (i, byte) in fraction.prefix(3).enumerated() {
                milli += Int64(byte - 48) * [100, 10, 1][i]
            }
        } else if b.count != 20 {
            return nil
        }
        guard (1...12).contains(month), (1...daysIn(month, year)).contains(day), hour < 24,
            minute < 60, second < 60
        else { return nil }
        let days = daysFromCivil(year, month, day)
        return days * msPerDay + hour * 3_600_000 + minute * 60_000 + second * 1000 + milli
    }

    static func daysFromCivil(_ y: Int64, _ m: Int64, _ d: Int64) -> Int64 {
        let year = m <= 2 ? y - 1 : y
        let era = floorDiv(year, 400)
        let yoe = year - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civil(fromDays z: Int64) -> (Int64, Int64, Int64) {
        let shifted = z + 719_468
        let era = floorDiv(shifted, 146_097)
        let doe = shifted - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    static func daysIn(_ month: Int64, _ year: Int64) -> Int64 {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    static func digits(_ b: [UInt8], _ start: Int, _ count: Int) -> Int64? {
        var value: Int64 = 0
        for byte in b[start..<(start + count)] {
            guard byte >= 48, byte <= 57 else { return nil }
            value = value * 10 + Int64(byte - 48)
        }
        return value
    }

    static func pad(_ value: Int64, _ width: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }
}
