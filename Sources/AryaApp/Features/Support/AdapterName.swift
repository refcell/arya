import Foundation

/// An adapter profile as people read it, shared by every lane: the connections catalog's
/// display name when it has one, else the profile id in words ("demo-lead_follow_up" reads
/// "Lead follow up", "fake-triage" reads "Triage (test)").
enum AdapterName {
    static func display(_ profile: String, named: String? = nil) -> String {
        if let named = named?.trimmingCharacters(in: .whitespaces), !named.isEmpty {
            return named
        }
        var words = profile.lowercased().split(whereSeparator: { "-_ .".contains($0) })
            .map(String.init)
        if words.first == "demo", words.count > 1 { words.removeFirst() }
        var test = false
        if ["fake", "stub", "mock"].contains(words.first ?? ""), words.count > 1 {
            words.removeFirst()
            test = true
        }
        guard let first = words.first else { return profile }
        let text = ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst())
            .joined(separator: " ")
        return test ? "\(text) (test)" : text
    }
}
