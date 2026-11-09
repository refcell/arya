import AryaDesign
import Foundation
import Testing

@Suite struct TimeTests {
    let now = Date(timeIntervalSince1970: 1_762_700_000)
    let utc = TimeZone(identifier: "UTC")!

    @Test func relativeUnderADayClockAfter() {
        func long(_ seconds: TimeInterval) -> String {
            AryaTime.label(now.addingTimeInterval(-seconds), now: now, timeZone: utc)
        }
        #expect(long(-30) == "just now")
        #expect(long(59) == "just now")
        #expect(long(240) == "4m ago")
        #expect(long(7200) == "2h ago")
        #expect(long(86_399) == "23h ago")
        #expect(long(86_400) == "Nov 8, 14:53")
    }

    @Test func shortLabelsFitASidebarRow() {
        func short(_ seconds: TimeInterval) -> String {
            AryaTime.label(
                now.addingTimeInterval(-seconds), now: now, style: .short, timeZone: utc)
        }
        #expect(short(10) == "now")
        #expect(short(240) == "4m")
        #expect(short(7200) == "2h")
        #expect(short(3 * 86_400) == "Nov 6")
        #expect(AryaTime.clock(now, timeZone: utc) == "14:53")
        #expect(AryaTime.clock(now, seconds: true, timeZone: utc) == "14:53:20")
    }
}
