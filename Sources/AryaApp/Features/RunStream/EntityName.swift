import AryaDesign
import Foundation
import SwiftUI

/// Entity refs as people read them: "person:alex" is "Alex", "tracker:ISSUE-7" is "ISSUE-7"
/// with "tracker" as a quiet suffix where there is room for one.
enum EntityName {
    /// Systems whose ids are people, shown as names.
    static let peopleSystems: Set<String> = ["person", "people", "user", "member"]

    // A ref: a lowercase system, a colon, an id that starts with a letter or digit. Not after a
    // letter, digit, slash or colon, so times ("09:01") and URLs stay as they are.
    private static let pattern = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_/:])([a-z][a-z0-9_]*):([A-Za-z0-9][A-Za-z0-9._-]*)"#)

    /// The name and system of `ref`, or `ref` itself with no system when it is not a ref.
    static func split(_ ref: String) -> (name: String, system: String?) {
        let trimmed = ref.trimmingCharacters(in: .whitespaces)
        guard let pattern,
            let match = pattern.firstMatch(
                in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
            match.range == NSRange(trimmed.startIndex..., in: trimmed),
            let system = Range(match.range(at: 1), in: trimmed).map({ String(trimmed[$0]) }),
            let id = Range(match.range(at: 2), in: trimmed).map({ String(trimmed[$0]) })
        else { return (ref, nil) }
        if peopleSystems.contains(system) { return (RunInput.person(id), nil) }
        return (id, system)
    }

    /// `ref` as a name, without its system.
    static func plain(_ ref: String) -> String { split(ref).name }

    /// Every ref in a sentence as a name: "Assign tracker:ISSUE-7 to person:alex" reads
    /// "Assign ISSUE-7 to Alex".
    static func humanize(_ text: String) -> String {
        guard let pattern, text.contains(":") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        var result = text
        for match in pattern.matches(in: text, range: range).reversed() {
            guard let whole = Range(match.range, in: result) else { continue }
            result.replaceSubrange(whole, with: plain(String(result[whole])))
        }
        return result
    }
}

/// A ref in a row: the name, then the system in a quieter color ("ISSUE-7 tracker").
struct EntityLabel: View {
    var ref: String
    var font: AryaTextStyle = AryaFont.mono
    var color: Color = AryaColor.ink

    var body: some View {
        let parts = EntityName.split(ref)
        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s1) {
            Text(parts.name).aryaText(font, color).lineLimit(1).truncationMode(.middle)
            if let system = parts.system {
                Text(system).aryaText(AryaFont.monoSmall, AryaColor.inkFaint).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The DRY RUN pill lists show next to a run's title (`RunTitle.Parts.isDryRun`).
struct DryRunPill: View {
    var body: some View {
        Text("DRY RUN").aryaText(AryaFont.label, AryaColor.inkMuted)
            .padding(.horizontal, AryaSpace.s1)
            .overlay(Capsule().strokeBorder(AryaColor.rule, lineWidth: 1))
            .accessibilityLabel("Dry run")
    }
}
