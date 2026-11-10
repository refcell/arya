import Foundation
import Testing

@testable import AryaApp

/// The preview charter (tracker; `person:alex` on the inbox) plus a `mail` relay, Sam on it
/// with a role and approvals, a message trigger from Sam, and two messages from Sam.
private func events() -> [FeatureEvent] {
    var log = FeatureEventBuilder(start: Date(timeIntervalSince1970: 1_800_000_000))
    var charter = PreviewFixtures.charter
    if case .object(var members) = charter {
        var bindings = members["bindings"]?.array ?? []
        bindings.append(["id": "mail", "kind": "mcp", "command": "mail-mcp", "actions": ["send"]])
        bindings.append([
            "id": "person:sam", "kind": "person", "channel": "sam@team", "via": "mail",
            "name": "Sam Lee", "role": "support lead", "actions": ["reply"],
        ])
        members["bindings"] = .array(bindings)
        members["triggers"] = [["kind": "manual"], ["kind": "message", "from": "person:sam"]]
        members["policy"] = [
            "default": "ask",
            "approvers": [
                ["action": "assign", "people": ["local", "person:sam"]],
                ["action": "send", "people": ["person:sam"]],
                ["action": "label", "binding": "tracker", "people": ["person:sam"]],
            ],
        ]
        charter = .object(members)
    }
    log.add("steward.created", actor: .localUser, ["charter": charter, "version": 3])
    log.add("inbox.message", ["from": "person:sam", "text": "first", "intent": "ask"])
    log.add("inbox.message", ["from": "person:sam", "text": "take ISSUE-9", "intent": "handoff"])
    return log.events
}

@Suite struct PeopleTests {
    @Test func readsPeopleWithRoleReachApprovalsAndMessages() throws {
        let directory = PeopleDirectory(events: events(), steward: PreviewFixtures.steward)
        #expect(directory.people.map(\.name) == ["Alex", "Sam Lee"])
        let sam = try #require(directory.people.last)
        #expect(sam.reach == "sam@team via mail")
        #expect(sam.role == "support lead")
        #expect(sam.messages == 2)
        #expect(sam.lastMessage == "take ISSUE-9")
        #expect(directory.relays == ["tracker", "mail"])
        #expect(directory.actionKinds == ["label", "comment", "assign", "send"])
        #expect(sam.approves == ["assign", "send"])
        #expect(directory.approvers(of: "assign") == ["local", "person:sam"])
        #expect(directory.approvers(of: "close") == nil)
        let names = (directory.approvers(of: "assign") ?? []).map(directory.approverName)
        #expect(ApproversText.line(names) == "May approve: You, Sam Lee (support lead)")
    }

    @Test func addingAPersonProposesANewBinding() throws {
        let directory = PeopleDirectory(events: events(), steward: PreviewFixtures.steward)
        var draft = PersonDraft()
        draft.name = "Rae Park"
        draft.approves = "refund, assign"
        let proposal = try #require(directory.saveProposal(draft, editing: nil))
        let rules = proposal.charter["policy"]?["approvers"]?.array ?? []
        #expect(rules.count == 4)
        #expect(rules[0]["people"] == ["local", "person:sam", "person:rae_park"])
        #expect(rules[3] == ["action": "refund", "people": ["local", "person:rae_park"]])
        #expect(proposal.charter["policy"]?["default"]?.string == "ask")
        #expect(proposal.baseVersion == 3)
        #expect(proposal.title == "Add Rae Park")
        let added = try #require(proposal.charter["bindings"]?.array?.last)
        #expect(added["id"]?.string == "person:rae_park")
        #expect(added["channel"]?.string == "inbox")
        #expect(added["role"] == nil)
        draft.name = "Alex"
        #expect(directory.saveProposal(draft, editing: nil) == nil)
    }

    @Test func editingKeepsTheIdAndUnmanagedFields() throws {
        let directory = PeopleDirectory(events: events(), steward: PreviewFixtures.steward)
        let sam = try #require(directory.people.last)
        var draft = PersonDraft(sam)
        draft.name = "Samantha Lee"
        draft.role = ""
        draft.via = ""
        let proposal = try #require(directory.saveProposal(draft, editing: sam.id))
        let bindings = proposal.charter["bindings"]?.array ?? []
        let edited = try #require(bindings.first { $0["id"]?.string == "person:sam" })
        #expect(bindings.count == 4)
        #expect(edited["name"]?.string == "Samantha Lee")
        #expect(edited["role"] == nil && edited["via"] == nil)
        #expect(edited["actions"]?.array?.compactMap(\.string) == ["reply"])
    }

    @Test func removingAPersonDropsTheirMessageTrigger() throws {
        let directory = PeopleDirectory(events: events(), steward: PreviewFixtures.steward)
        let proposal = try #require(directory.removeProposal("person:sam"))
        let ids = (proposal.charter["bindings"]?.array ?? []).compactMap { $0["id"]?.string }
        #expect(!ids.contains("person:sam"))
        #expect(proposal.charter["triggers"]?.array?.count == 1)
        // Sam leaves every unscoped rule; a rule left empty names the person at this home, and
        // the binding-scoped rule is untouched.
        let rules = proposal.charter["policy"]?["approvers"]?.array ?? []
        #expect(rules[0]["people"] == ["local"])
        #expect(rules[1]["people"] == ["local"])
        #expect(rules[2]["people"] == ["person:sam"])
        #expect(directory.removeProposal("person:nobody") == nil)
    }

    @Test func draftIssuesAndNavigation() {
        var draft = PersonDraft()
        #expect(draft.issues == ["Give the person a name."])
        draft.name = "Kai"
        draft.via = "mail"
        #expect(draft.issues == ["Give their address on mail."])
        var state = NavigationState()
        state.select(steward: "st_a")
        state.showConnections()
        state.showPeople()
        #expect(state.destination == .people(steward: "st_a"))
        #expect(state.pageSteward == "st_a")
    }
}
