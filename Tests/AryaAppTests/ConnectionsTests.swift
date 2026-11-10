import Arya
import Foundation
import Testing

@testable import AryaApp

/// Two stewards: triage binds `tracker` (from the preview charter) and a `mail` relay that
/// `person:sam` is reached through; digest has no bindings and runs on another adapter.
private func events() -> [FeatureEvent] {
    var log = FeatureEventBuilder(start: Date(timeIntervalSince1970: 1_800_000_000))
    var triage = PreviewFixtures.charter
    if case .object(var members) = triage {
        var bindings = members["bindings"]?.array ?? []
        bindings.append([
            "id": "mail", "kind": "mcp", "command": "mail-mcp", "args": ["--local"],
            "read": ["receive"], "actions": ["send"], "network": true,
        ])
        bindings.append(["id": "person:sam", "kind": "person", "channel": "sam", "via": "mail"])
        members["bindings"] = .array(bindings)
        triage = .object(members)
    }
    log.add("steward.created", actor: .localUser, ["charter": triage, "version": 1])
    log.add(
        "steward.created", steward: "st_digest", actor: .localUser,
        ["charter": ["id": "st_digest", "name": "Digest", "adapter": "fake"], "version": 1])
    log.add(
        "action.proposed", run: "run_1",
        ["action": ["id": "a1", "kind": "assign"], "risk": "high"])
    return log.events
}

@Suite struct ConnectionsCatalogTests {
    @Test func listsConnectionsWithReadsActionsRiskAndStewards() throws {
        let catalog = ConnectionsCatalog(events: events())
        #expect(catalog.entries.map(\.id) == ["tracker", "mail"])
        let tracker = try #require(catalog.entries.first)
        #expect(tracker.read == ["search", "get"])
        #expect(tracker.actions.first { $0.kind == "assign" }?.risk == "high")
        #expect(tracker.connected == [PreviewFixtures.steward])
        #expect(tracker.declared == ["search", "get", "label", "comment", "assign"])
        let mail = try #require(catalog.entries.last)
        #expect(mail.network)
        #expect(mail.commandLine == "mail-mcp --local")
        #expect(catalog.adapters.map(\.name) == ["exec-default", "fake"])
        #expect(tracker.actions.first { $0.kind == "label" }?.risk == "low")
        #expect(tracker.actions.first { $0.kind == "comment" }?.risk == "medium")
    }

    @Test func aConnectedStewardSeesItsOwnBinding() throws {
        var log = FeatureEventBuilder(start: Date(timeIntervalSince1970: 1_800_000_000))
        log.add("steward.created", actor: .localUser, ["charter": PreviewFixtures.charter])
        let other: FeatureJSON = [
            "id": "st_other", "adapter": "fake",
            "bindings": [
                ["id": "tracker", "kind": "mcp", "command": "tracker-mcp", "actions": ["close"]]
            ],
        ]
        log.add("steward.created", steward: "st_other", actor: .localUser, ["charter": other])
        let catalog = ConnectionsCatalog(events: log.events)
        let tracker = try #require(catalog.entries.first)
        #expect(tracker.actions.map(\.kind) == ["close"])
        let own = catalog.entry(tracker, for: PreviewFixtures.steward)
        #expect(own.actions.map(\.kind) == ["label", "comment", "assign"])
        #expect(catalog.entry(tracker, for: nil) == tracker)
    }

    @Test func connectProposesTheBindingOnTheLiveCharter() throws {
        let catalog = ConnectionsCatalog(events: events())
        let tracker = try #require(catalog.entries.first)
        #expect(catalog.connectProposal(tracker, steward: PreviewFixtures.steward) == nil)
        let proposal = try #require(catalog.connectProposal(tracker, steward: "st_digest"))
        #expect(proposal.baseVersion == 1)
        #expect(proposal.title == "Connect tracker")
        let bindings = proposal.charter["bindings"]?.array ?? []
        #expect(bindings.map { $0["id"]?.string } == ["tracker"])
        #expect(bindings.first?["actions"]?.array?.count == 3)
        #expect(proposal.charter["adapter"]?.string == "fake")
    }

    @Test func disconnectRemovesTheBindingUnlessPeopleRelayThroughIt() throws {
        let catalog = ConnectionsCatalog(events: events())
        let tracker = try #require(catalog.entries.first)
        let mail = try #require(catalog.entries.last)
        let steward = PreviewFixtures.steward
        let proposal = try #require(catalog.disconnectProposal(tracker, steward: steward))
        let ids = (proposal.charter["bindings"]?.array ?? []).compactMap { $0["id"]?.string }
        #expect(ids == ["person:alex", "mail", "person:sam"])
        #expect(catalog.disconnectBlocker(mail, steward: steward) != nil)
        #expect(catalog.disconnectProposal(mail, steward: steward) == nil)
        #expect(catalog.disconnectProposal(tracker, steward: "st_digest") == nil)
    }

    @Test func testLineNamesMissingTools() {
        #expect(
            ConnectionTestText.line(ConnectionTest(ok: true, tools: ["a", "b"]))
                == "Connected · 2 tools, every declared tool offered")
        let full = ConnectionTest(
            ok: true, server: "inbox", tools: ["history"], servesHistory: true,
            latencyMilliseconds: 12)
        #expect(
            ConnectionTestText.line(full)
                == "Connected to inbox in 12 ms · 1 tool, every declared tool offered · history")
        #expect(
            ConnectionTestText.line(ConnectionTest(ok: true, tools: ["a"], missing: ["b"]))
                == "Connected · 1 tool, missing b"
        )
        #expect(
            ConnectionsFailure(FeatureReadError.unavailable("connection tests")).text
                == "connection tests is not available here")
    }

    @Test func navigationKeepsTheConnectionsStewardValid() {
        var state = NavigationState()
        state.select(steward: "st_a")
        state.showConnections()
        #expect(state.destination == .connections(steward: "st_a"))
        #expect(state.steward == nil)
        state.showConnections(steward: "st_b")
        state.reconcile(stewards: ["st_a"], runs: [])
        #expect(state.destination == .connections(steward: "st_a"))
        #expect(RailOrder.current(state) == nil)
    }
}
