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
    @Test func aRelayCarriesItsPeopleAndShowsTheirLatestMessages() throws {
        var log = events()
        var builder = FeatureEventBuilder(start: Date(timeIntervalSince1970: 1_800_000_100))
        for text in ["one", "two", "three", "four"] {
            builder.add(
                "inbox.message", actor: FeatureActor(kind: .human, id: "person:sam"),
                ["from": "person:sam", "channel": "sam", "via": "mail", "text": .string(text)])
        }
        builder.add("inbox.message", ["from": "person:alex", "channel": "inbox", "text": "x"])
        let base = log.map(\.seq).max() ?? 0
        log += builder.events.map {
            var event = $0
            event.seq += base
            return event
        }
        let catalog = ConnectionsCatalog(events: log)
        let mail = try #require(catalog.entries.first { $0.id == "mail" })
        let carries = try #require(ConnectionsText.carries(catalog, entry: mail, events: log))
        #expect(carries.hasPrefix("Sam ("))
        let tracker = try #require(catalog.entries.first { $0.id == "tracker" })
        #expect(ConnectionsText.carries(catalog, entry: tracker, events: log) == nil)
        let relayed = ConnectionsText.relayed("mail", events: log)
        #expect(relayed.map { $0.payload["text"]?.string } == ["four", "three", "two"])
    }

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

    @Test func capabilitiesReadAsOneMonoLine() throws {
        let catalog = ConnectionsCatalog(events: events())
        let tracker = try #require(catalog.entries.first)
        #expect(
            ConnectionsText.capabilities(tracker)
                == "reads: search, get · does: label (low), comment (medium), assign (high)")
        #expect(ConnectionsText.lastTest(nil) == "Not tested yet")
        #expect(
            ConnectionsText.lastTest(ConnectionTest(ok: false, problem: "could not start"))
                == "Failed · could not start")
    }

    @Test func theInspectorFollowsTheSelectedConnection() {
        var state = NavigationState()
        state.select(steward: "st_a")
        state.showConnections()
        #expect(InspectorFocus.of(state) == InspectorFocus.none)
        state.select(connection: "tracker")
        #expect(state.inspector)
        #expect(InspectorFocus.of(state) == .connection("tracker"))
        state.select(steward: "st_a")
        #expect(InspectorFocus.of(state) == .steward("st_a"))
    }

    @Test func navigationKeepsTheConnectionsStewardValid() {
        var state = NavigationState()
        state.select(steward: "st_a")
        state.showConnections()
        #expect(state.destination == .connections(steward: nil))
        #expect(state.steward == nil)
        state.showConnections(steward: "st_b")
        state.reconcile(stewards: ["st_a"], runs: [])
        #expect(state.destination == .connections(steward: "st_a"))
        #expect(RailOrder.current(state) == nil)
    }
}

@Suite struct ConnectionActivityTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func events() -> [FeatureEvent] {
        var log = FeatureEventBuilder(start: start)
        func tool(_ name: String, run: String) {
            log.add(
                "run.adapter.event", run: run,
                [
                    "message": [
                        "method": "run/event",
                        "params": [
                            "event": ["kind": "tool_call", "id": "t", "tool": .string(name)]
                        ],
                    ]
                ])
        }
        tool("inbox.search", run: "run_1")
        tool("nodot", run: "run_1")
        log.add(
            "action.proposed", run: "run_1",
            ["action": ["id": "a1", "kind": "label", "binding": "inbox", "target": "inbox:MSG-1"]])
        log.add("action.executed", run: "run_1", ["action": "a1"])
        log.add(
            "action.proposed", run: "run_2", after: 86400,
            ["action": ["id": "a1", "kind": "refund", "binding": "billing", "target": "ORDER-9"]])
        log.add("action.failed", run: "run_2", ["action": "a1"])
        log.add(
            "action.proposed", run: "run_3",
            ["action": ["id": "a1", "kind": "reply", "binding": "inbox", "target": "inbox:MSG-2"]])
        return log.events
    }

    @Test func readsAndActionsAreCallsThroughTheirConnection() {
        let activity = ConnectionActivity(events: events())
        #expect(
            activity.recent("inbox").map(\.what) == [
                "reply inbox:MSG-2", "label inbox:MSG-1", "search",
            ])
        #expect(activity.recent("inbox").map(\.kind) == [.proposed, .did, .read])
        #expect(activity.recent("billing").map(\.kind) == [.failed])
        #expect(activity.calls["nodot"] == nil)
    }

    @Test func dailyCountsEndToday() {
        let activity = ConnectionActivity(events: events())
        let now = start.addingTimeInterval(86400 + 600)
        let daily = activity.daily("inbox", now: now)
        #expect(daily.count == 7)
        #expect(daily.reduce(0, +) == 3)
        #expect(activity.count("billing", now: now) == 1)
        #expect(activity.count("billing", now: now.addingTimeInterval(8 * 86400)) == 0)
    }

    /// A relay carries replies to the people it reaches and what they send in, so chat shows
    /// calls while Lee is reached through it.
    @Test func aRelayCountsRepliesToItsPeopleAndMessagesIn() throws {
        var log = FeatureEventBuilder(start: start)
        log.add(
            "inbox.message", actor: FeatureActor(kind: .human, id: "person:lee"),
            ["from": "person:lee", "via": "chat", "intent": "ask", "text": "Is it down?"])
        log.add(
            "action.proposed", run: "run_9",
            ["action": ["id": "a1", "kind": "reply", "binding": "person:lee"]])
        log.add("action.executed", run: "run_9", ["action": "a1", "dryRun": true])
        let relays = ["chat": [PreviewFixtures.steward: ["person:lee"]]]
        let activity = ConnectionActivity(events: log.events, relays: relays)
        #expect(activity.recent("chat").map(\.what) == ["reply Lee", "message from Lee"])
        #expect(activity.recent("chat").map(\.kind) == [.did, .received])
        #expect(activity.recent("person:lee").map(\.kind) == [.did])
        let last = try #require(activity.lastSettled("chat"))
        #expect(
            ConnectionsText.evidence(last, now: last.at.addingTimeInterval(7200))
                == "working · last call 2h ago")
        #expect(ConnectionsText.evidence(nil, now: start) == nil)
        #expect(ConnectionsText.secret(stored: false, network: false) == "no secret needed")
        #expect(ConnectionsText.secret(stored: false, network: true) == "no secret")
        #expect(ConnectionsText.secret(stored: true, network: true) == "secret stored")
    }
}

@Suite struct PeopleChannelsTests {
    @Test func theInboxAndEachRelayPeopleUseAreChannels() throws {
        var log = events()
        var builder = FeatureEventBuilder(start: Date(timeIntervalSince1970: 1_800_000_100))
        builder.add(
            "inbox.message", actor: FeatureActor(kind: .human, id: "person:sam"),
            ["from": "person:sam", "channel": "sam", "via": "mail", "intent": "ask", "text": "Hi"])
        let base = log.map(\.seq).max() ?? 0
        log += builder.events.map {
            var event = $0
            event.seq += base
            return event
        }
        let channels = PeopleChannels(
            events: log, steward: PreviewFixtures.steward,
            now: Date(timeIntervalSince1970: 1_800_000_200)
        ).channels
        #expect(channels.map(\.id) == ["inbox", "mail"])
        let mail = try #require(channels.last)
        #expect(mail.relay && mail.bound)
        #expect(mail.people.count == 1)
        #expect(mail.inbound == 1)
        #expect(mail.daily.last == 1)
        #expect(mail.last?.text == "Hi")
    }
}

@Suite struct PeopleRosterTests {
    @Test func everyoneOnceWithTheirStewardsAndDepartments() throws {
        var log = FeatureEventBuilder(start: Date(timeIntervalSince1970: 1_800_000_000))
        func steward(_ id: String, department: String, people: [FeatureJSON]) {
            log.add(
                "steward.created", steward: id, actor: .localUser,
                [
                    "charter": [
                        "id": .string(id), "name": .string(id), "adapter": "fake",
                        "department": .string(department), "bindings": .array(people),
                    ],
                    "version": 1,
                ])
        }
        let sam: FeatureJSON = [
            "id": "person:sam", "kind": "person", "channel": "inbox", "name": "Sam",
            "role": "support lead", "actions": ["reply"],
        ]
        steward("st_a", department: "Support", people: [sam])
        steward(
            "st_b", department: "Billing",
            people: [
                sam,
                ["id": "person:priya", "kind": "person", "channel": "inbox", "name": "Priya"],
            ])
        let roster = PeopleRoster(events: log.events, stewards: ["st_a", "st_b"])
        #expect(roster.people.map(\.name) == ["Sam", "Priya"])
        let first = try #require(roster.people.first)
        #expect(first.stewards == ["st_a", "st_b"])
        #expect(first.departments == ["Support", "Billing"])
        #expect(roster.notWith("st_a").map(\.name) == ["Priya"])
        #expect(RosterText.names(["A", "B", "C", "D"]) == "A, B +2")
        #expect(RosterText.names(["A"]) == "A")
        #expect(PeopleText.approves([]) == nil)
        #expect(PeopleText.approves(["follow_up", "*"]) == "approves follow-up, any action")
    }

    /// Lena works with two stewards but wrote to the second: she opens there, and her row
    /// counts the same thread the inspector does.
    @Test func aPersonOpensWithTheStewardTheyTalkTo() throws {
        var log = FeatureEventBuilder(start: Date(timeIntervalSince1970: 1_800_000_000))
        let lena: FeatureJSON = [
            "id": "person:lena", "kind": "person", "channel": "inbox", "name": "Lena",
        ]
        for id in ["st_a", "st_b"] {
            log.add(
                "steward.created", steward: id, actor: .localUser,
                [
                    "charter": [
                        "id": .string(id), "name": .string(id), "adapter": "fake",
                        "bindings": [lena],
                    ],
                    "version": 1,
                ])
        }
        log.add(
            "inbox.message", steward: "st_b", actor: FeatureActor(kind: .human, id: "person:lena"),
            ["from": "person:lena", "intent": "correct", "text": "Not lapsed yet."])
        let person = try #require(
            PeopleRoster(events: log.events, stewards: ["st_a", "st_b"]).people.first)
        #expect(person.stewards == ["st_b", "st_a"])
        #expect(person.inbound == 1)
        #expect(person.outbound == 0)
    }
}
