import AryaAdapters
import AryaCore
import Foundation
import Testing

@testable import Arya

@Test func portfolioGroupsStewardsByDepartment() async throws {
    let opened = try await Opened([FakeScript.Run(result: liveResult)])
    let workspace = opened.workspace
    var support = try Charter.load(from: try inboxCharterJSON(id: "st_support"))
    support.department = "Support"
    support.owner = "person:alex"
    support.metric.target = 0.9
    var other = try Charter.load(from: try inboxCharterJSON(id: "st_other"))
    other.name = "Other"
    _ = try await workspace.createSteward(charter: try CanonicalJSON.encode(support))
    _ = try await workspace.createSteward(charter: try CanonicalJSON.encode(other))
    _ = try await workspace.createFromTemplate("vendor_spend_review", adapter: "fake")
    _ = try await workspace.startRun(steward: "st_support", input: "New message MSG-9")

    let portfolio = try await workspace.portfolio(windows: 7)

    #expect(portfolio.groups.map(\.department) == ["Finance", "Support", "Unassigned"])
    let item = try #require(portfolio.groups[1].items.first)
    #expect(item.fleet.steward == "st_support")
    #expect(item.owner == "person:alex")
    #expect(item.outcome.hasPrefix("Every new message"))
    #expect(item.direction == "up")
    #expect(!item.trend.isEmpty && item.trend.count <= 7)
    #expect(item.fleet.target == 0.9)
    #expect(portfolio.needsYou == 1)
    #expect(portfolio.onTrack + portfolio.offTrack + portfolio.unmeasured == 3)
}

@Test func everyTemplateMakesAValidSteward() async throws {
    let opened = try await Opened()
    let workspace = opened.workspace
    let templates = workspace.templates()
    #expect(templates.count == 5)
    #expect(Set(templates.map(\.id)).count == 5)
    for template in templates {
        let charter = try template.draft.charter()
        #expect(charter.validate().isEmpty, "\(template.id): \(charter.validate())")
        #expect(charter.department == template.department)
        #expect(!template.summary.isEmpty && template.summary.count <= 100)
        let created = try await workspace.createFromTemplate(template.id)
        #expect(created.id == "st_" + template.id)
    }
    let renamed = try await workspace.createFromTemplate(
        "lead_follow_up", name: "Partner leads", adapter: "fake", owner: "person:sam")
    #expect(renamed.id == "st_partner_leads")
    let charter = try Charter.load(from: try await workspace.charter("st_partner_leads"))
    #expect(charter.name == "Partner leads")
    #expect(charter.adapter == "fake")
    #expect(charter.owner == "person:sam")
    #expect(charter.autonomy == .suggest)
    await #expect(throws: WorkspaceError.notFound("nope")) {
        try await workspace.createFromTemplate("nope")
    }
}

/// `etc/examples/templates/<id>.json` matches the catalog; `ARYA_REGEN_TEMPLATES=1` rewrites
/// the files.
@Test func templateFilesMatchTheCatalog() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let directory = root.appendingPathComponent("etc/examples/templates")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let regenerate = ProcessInfo.processInfo.environment["ARYA_REGEN_TEMPLATES"] == "1"
    for template in StewardTemplates.all {
        let file = directory.appendingPathComponent("\(template.id).json")
        let expected = try encoder.encode(try template.draft.charter()) + Data("\n".utf8)
        if regenerate {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try expected.write(to: file)
        }
        let stored = try Data(contentsOf: file)
        #expect(stored == expected, "\(file.lastPathComponent) is out of date")
        #expect(try Charter.load(from: stored) == template.draft.charter())
    }
}
