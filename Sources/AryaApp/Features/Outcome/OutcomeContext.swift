import AryaDesign
import SwiftUI

/// What the steward knows about, one line each: the people and connections in its charter,
/// the newest live memory notes, and its newest live decisions (from each run's recorded
/// result; rehearsals left out).
struct OutcomeContext: Hashable, Sendable {
    struct Line: Hashable, Sendable, Identifiable {
        var id: String
        /// Machine text, shown in mono: an id, a choice.
        var key: String
        /// Plain words after it.
        var text: String
    }

    var people: [Line] = []
    var connections: [Line] = []
    var notes: [Line] = []
    var decisions: [Line] = []

    var isEmpty: Bool {
        people.isEmpty && connections.isEmpty && notes.isEmpty && decisions.isEmpty
    }

    /// Lines per group.
    static let limit = 3

    static func build(events: [FeatureEvent], steward: String) -> OutcomeContext {
        var out = OutcomeContext()
        let charter = LiveCharter.find(events: events, steward: steward)?.charter
        for binding in charter?["bindings"]?.array ?? [] {
            guard let id = binding["id"]?.string else { continue }
            if binding["kind"]?.string == "person" {
                let name =
                    binding["name"]?.string
                    ?? (id.hasPrefix("person:") ? String(id.dropFirst(7)).capitalized : id)
                out.people.append(
                    Line(
                        id: id, key: name,
                        text: "reached on " + (binding["channel"]?.string ?? "inbox")))
            } else {
                let actions = (binding["actions"]?.array ?? []).compactMap(\.string)
                out.connections.append(
                    Line(
                        id: id, key: id,
                        text: actions.isEmpty ? "read only" : actions.joined(separator: " · ")))
            }
        }
        out.notes = MemoryList.build(events: events, steward: steward).live.prefix(limit).map {
            Line(id: $0.id, key: $0.tags.first ?? "note", text: $0.text)
        }
        let rehearsals = OutcomeRuns.rehearsalRuns(events)
        var decisions: [Line] = []
        for event in events.reversed() where event.steward == steward || event.steward == nil {
            guard decisions.count < limit, event.type == "run.adapter.event",
                let run = event.run, !rehearsals.contains(run),
                let message = event.payload["message"], message["method"]?.string == "run/result"
            else { continue }
            for decision in message["params"]?["result"]?["decisions"]?.array ?? [] {
                guard decisions.count < limit, let choice = decision["choice"]?.string else {
                    continue
                }
                let why = decision["why"]?.string ?? decision["rationale"]?.string ?? ""
                decisions.append(
                    Line(id: "\(run)/\(decision["id"]?.string ?? choice)", key: choice, text: why))
            }
        }
        out.decisions = decisions
        return out
    }
}

/// The Overview's CONTEXT section, collapsed by default.
struct OutcomeContextSection: View {
    let context: OutcomeContext
    @AryaState private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            Button {
                open.toggle()
            } label: {
                HStack(spacing: AryaSpace.s1) {
                    Text(open ? "▾" : "▸").aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                    Text("Context").aryaText(AryaFont.overline, AryaColor.inkFaint)
                    if !open {
                        Text(summary).aryaText(AryaFont.caption, AryaColor.inkFaint)
                            .padding(.leading, AryaSpace.s2)
                    }
                }
            }
            .buttonStyle(.plain)
            if open {
                group("People", context.people)
                group("Connections", context.connections)
                group("Knows", context.notes)
                group("Decided lately", context.decisions)
            }
        }
    }

    private var summary: String {
        [
            (context.people.count, "person", "people"),
            (context.connections.count, "connection", "connections"),
            (context.notes.count, "note", "notes"),
            (context.decisions.count, "decision", "decisions"),
        ]
        .filter { $0.0 > 0 }.map { "\($0.0) \($0.0 == 1 ? $0.1 : $0.2)" }
        .joined(separator: " · ")
    }

    @ViewBuilder
    private func group(_ title: String, _ lines: [OutcomeContext.Line]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: AryaSpace.s1) {
                Text(title).aryaText(AryaFont.caption, AryaColor.inkMuted)
                ForEach(lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                        Text(line.key).aryaText(AryaFont.mono, AryaColor.ink)
                        Text(line.text).aryaText(AryaFont.body, AryaColor.inkMuted)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
            }
            .padding(.top, AryaSpace.s1)
        }
    }
}
