import Foundation
import Testing

@testable import AryaCore

@Test func timestampFormatsUTCWithMillis() {
    #expect(Timestamp(millis: 0).description == "1970-01-01T00:00:00.000Z")
    #expect(Timestamp(millis: 1_767_225_600_000).description == "2026-01-01T00:00:00.000Z")
    #expect(Timestamp(millis: 951_782_400_123).description == "2000-02-29T00:00:00.123Z")
    #expect(Timestamp(millis: -1).description == "1969-12-31T23:59:59.999Z")
}

@Test(arguments: [0, -1, 951_782_400_123, 1_767_225_600_000, 4_102_444_799_999])
func timestampRoundTrips(millis: Int64) {
    let stamp = Timestamp(millis: millis)
    #expect(Timestamp(stamp.description) == stamp)
}

@Test func timestampParsing() {
    #expect(Timestamp("2026-01-01T12:00:00Z")?.millis == 1_767_268_800_000)
    #expect(Timestamp("2026-01-01T12:00:00.5Z")?.millis == 1_767_268_800_500)
    #expect(Timestamp("2026-01-01T12:00:00.123456Z")?.millis == 1_767_268_800_123)
    #expect(Timestamp("2026-02-30T00:00:00Z") == nil)
    #expect(Timestamp("2026-01-01 12:00:00Z") == nil)
    #expect(Timestamp("2026-01-01T12:00:00.Z") == nil)
    #expect(Timestamp("2026-01-01T12:00:00+01:00") == nil)
}

@Test func timestampEncodesAsText() throws {
    let stamp = Timestamp(millis: 1_767_268_800_250)
    #expect(try CanonicalJSON.string([stamp]) == #"["2026-01-01T12:00:00.250Z"]"#)
}
