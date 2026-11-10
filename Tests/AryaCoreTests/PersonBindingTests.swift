import Foundation
import Testing

@testable import AryaCore

@Test func personNameAndRoleRoundTripAndStayOptional() throws {
    var person = CharterBinding.person("person:alex", channel: "inbox")
    let bare = try CanonicalJSON.string(person)
    #expect(!bare.contains("role") && !bare.contains("name"))
    person.name = "Alex Kim"
    person.role = "support lead"
    let text = try CanonicalJSON.string(person)
    let back = try JSONDecoder().decode(CharterBinding.self, from: Data(text.utf8))
    #expect(back == person)
    #expect(back.role == "support lead")
}
