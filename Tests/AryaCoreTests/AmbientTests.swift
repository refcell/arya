import Foundation
import Testing

@testable import AryaCore

private func sample(_ ambient: Ambient) -> [String] {
    var out: [String] = []
    for _ in 0..<5 {
        out.append(ambient.now().description)
        out.append(ambient.newID(RunID.self).rawValue)
        out.append(String(ambient.nextRandom()))
        out.append(String(ambient.random(in: 0..<10)))
    }
    return out
}

@Test func twoFixedAmbientsProduceIdenticalSequences() {
    let first = sample(.fixed(seed: 7))
    #expect(first == sample(.fixed(seed: 7)))
    #expect(first != sample(.fixed(seed: 8)))
}

@Test func fixedClockSteps() {
    let ambient = Ambient.fixed(start: Timestamp(millis: 1000), stepMillis: 250)
    #expect([ambient.now(), ambient.now(), ambient.now()].map(\.millis) == [1000, 1250, 1500])
}

@Test func idsCarryPrefixAndTime() {
    let ambient = Ambient.fixed(start: Timestamp(millis: 1_767_225_600_000))
    _ = ambient.now()
    let id = ambient.newID(EventID.self)
    #expect(id.rawValue.hasPrefix("ev_01KDVDNA00"))
    #expect(id.body.count == 26)
    #expect(EventID.isValid(id.rawValue))
}

@Test func recordedAmbientReplaysReadings() {
    let source = Ambient.fixed(seed: 3)
    let original = sample(source)
    let replay = Ambient.recorded(source.drainReadings())
    #expect(sample(replay) == original)
    #expect(replay.mismatches.isEmpty)
    #expect(replay.isExhausted)
}

@Test func recordedAmbientReportsMismatches() {
    let replay = Ambient.recorded([.time(Timestamp(millis: 5))])
    _ = replay.newID(RunID.self)
    _ = replay.now()
    #expect(replay.mismatches.count == 2)
    #expect(replay.mismatches[0].contains("wanted id"))
    #expect(replay.mismatches[1].contains("recording ended"))
}

@Test func drainEmptiesTheLog() {
    let ambient = Ambient.fixed()
    _ = ambient.now()
    #expect(ambient.drainReadings().count == 1)
    #expect(ambient.drainReadings().isEmpty)
}

@Test func readingsCodeWithKinds() throws {
    let readings: [AmbientReading] = [.time(Timestamp(millis: 0)), .id("run_1"), .random(9)]
    let text = try CanonicalJSON.string(readings)
    #expect(
        text == #"[{"kind":"time","value":"1970-01-01T00:00:00.000Z"},"#
            + #"{"kind":"id","value":"run_1"},{"kind":"random","value":9}]"#)
    #expect(try JSONDecoder().decode([AmbientReading].self, from: Data(text.utf8)) == readings)
}

@Test func liveAmbientWorks() {
    let ambient = Ambient.live
    #expect(ambient.now().millis > 1_700_000_000_000)
    #expect(ambient.newID(RunID.self) != ambient.newID(RunID.self))
}

@Test func fixedIDsMadeBeforeTheFirstReadingCarryTheStartTime() {
    let start = Timestamp(millis: 1_767_225_600_000)
    let ambient = Ambient.fixed(start: start)
    let first = ambient.newID(RunID.self).rawValue.dropFirst("run_".count)
    #expect(
        first.prefix(10)
            == ULID.encode(millis: start.millis, randomHigh: 0, randomLow: 0)
            .prefix(10))
    #expect(ambient.now() == start)
}
