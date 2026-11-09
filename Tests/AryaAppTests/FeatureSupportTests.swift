import Foundation
import Testing

@testable import AryaApp

@Test func compactTextSortsKeysAndEscapes() {
    let value: FeatureJSON = ["b": [1, 2.5, nil, true], "a": "say \"hi\"\n"]
    #expect(value.compactText == #"{"a":"say \"hi\"\n","b":[1,2.5,null,true]}"#)
}

@Test func jsonDecodesEveryKind() throws {
    let text = #"{"n":3,"s":"x","b":false,"z":null,"l":["y"],"o":{"k":1}}"#
    let value = try JSONDecoder().decode(FeatureJSON.self, from: Data(text.utf8))
    #expect(value["n"]?.number == 3)
    #expect(value["s"]?.string == "x")
    #expect(value["b"]?.bool == false)
    #expect(value["z"] == .null)
    #expect(value["l"]?.strings == ["y"])
    #expect(value["o"]?["k"]?.number == 1)
    #expect(value["missing"] == nil)
}

@Test func timesFormatDeterministically() {
    let now = FeatureTestClock.now
    #expect(FeatureTime.relative(now.addingTimeInterval(-30), now: now) == "just now")
    #expect(FeatureTime.relative(now.addingTimeInterval(-120), now: now) == "2m ago")
    #expect(FeatureTime.relative(now.addingTimeInterval(-7200), now: now) == "2h ago")
    #expect(FeatureTime.relative(now.addingTimeInterval(-172_800), now: now) == "Jan 13")
    let utc = TimeZone(identifier: "UTC") ?? .current
    let epoch = Date(timeIntervalSince1970: 0)
    #expect(FeatureTime.absolute(epoch, timeZone: utc) == "1 Jan 1970, 00:00")
    #expect(FeatureTime.duration(0.85) == "850 ms")
    #expect(FeatureTime.duration(4.2) == "4.2 s")
    #expect(FeatureTime.duration(185) == "3m 5s")
}

@Test func approvingRecordsLocalUserThenExecution() async throws {
    let workspace = PreviewWorkspace.triage(now: FeatureTestClock.now)
    let approval = PreviewFixtures.pendingApproval
    let before = await workspace.events().count
    let written = try await workspace.record(.approve(approval: approval))
    #expect(written.map(\.type) == ["approval.granted", "action.executed"])
    #expect(written[0].actor == .localUser)
    #expect(written.map(\.seq) == [before + 1, before + 2])
    await #expect(throws: FeatureWriteError.alreadyDecided(approval)) {
        try await workspace.record(.deny(approval: approval, reason: ""))
    }
    await #expect(throws: FeatureWriteError.unknownApproval("ap_nope")) {
        try await workspace.record(.approve(approval: "ap_nope"))
    }
}

@MainActor
@Test func storeLoadsAndReportsWriteErrors() async {
    let now = FeatureTestClock.now
    let store = FeatureStore(workspace: PreviewWorkspace.triage(now: now), now: now)
    await store.reload()
    #expect(store.events.count == PreviewFixtures.triage(now: now).count)
    #expect(await store.perform(.approve(approval: "ap_nope")) == false)
    #expect(store.writeError?.contains("ap_nope") == true)
    #expect(await store.perform(.approve(approval: PreviewFixtures.pendingApproval)))
    #expect(store.writeError == nil)
}

@MainActor
@Test func storeReloadsWhenTheWorkspaceChanges() async throws {
    let workspace = PreviewWorkspace.triage(now: FeatureTestClock.now)
    let store = FeatureStore(workspace: workspace, now: FeatureTestClock.now)
    let observer = Task { await store.observe() }
    defer { observer.cancel() }
    let initial = PreviewFixtures.triage(now: FeatureTestClock.now).count
    var builder = FeatureEventBuilder(start: FeatureTestClock.now)
    builder.add("run.finished", run: PreviewFixtures.liveRun, ["status": "completed"])
    var event = builder.events[0]
    event.seq = initial + 1
    await workspace.append([event])
    // The subscription registers asynchronously; nudge until a notification lands.
    try await waitUntil {
        if store.events.count != initial + 1 { await workspace.append([]) }
        return store.events.count == initial + 1
    }
}

/// Feature views take every color, font, and size from AryaDesign tokens (docs/STYLE.md).
@Test func featureViewsUseOnlyDesignTokens() throws {
    let features = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/AryaApp/Features")
    let forbidden = [
        " Color(", "(Color(", " Color.", "(Color.", ".font(", "size:", "NSColor", ".padding(4",
        ".padding(8",
        ".padding(1", ".padding(2", ".frame(width: 1", ".frame(height: 1",
    ]
    let files = FileManager.default.enumerator(at: features, includingPropertiesForKeys: nil)
    var hits: [String] = []
    while let url = files?.nextObject() as? URL {
        guard url.pathExtension == "swift" else { continue }
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (number, line) in lines.enumerated()
        where forbidden.contains(where: { line.contains($0) && !line.contains("AryaColor") }) {
            hits.append("\(url.lastPathComponent):\(number + 1)")
        }
    }
    #expect(hits.isEmpty, "literal styles in feature views: \(hits)")
}

/// One time rule (STYLE.md Time): app code formats dates only through `AryaTime`.
@Test func appCodeNeverFormatsDatesItself() throws {
    let app = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/AryaApp")
    let forbidden = [
        "DateFormatter", ".formatted(", "RelativeDateTimeFormatter", "DateComponentsFormatter",
        "Date.FormatStyle", ".time.relative", ".time.absolute",
    ]
    let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
    var hits: [String] = []
    while let url = files?.nextObject() as? URL {
        guard url.pathExtension == "swift" else { continue }
        let lines = try String(contentsOf: url, encoding: .utf8).split(
            separator: "\n", omittingEmptySubsequences: false)
        for (number, line) in lines.enumerated() where forbidden.contains(where: line.contains) {
            hits.append("\(url.lastPathComponent):\(number + 1)")
        }
    }
    #expect(hits.isEmpty, "date formatting outside AryaTime: \(hits)")
}
