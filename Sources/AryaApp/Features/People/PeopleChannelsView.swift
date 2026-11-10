import Arya
import AryaDesign
import SwiftUI

/// The Channels pane on People: the local inbox and each relay a steward's people reach it
/// through, with its status, who uses it, the week's volume as a sparkline, and the last
/// message.
struct PeopleChannelsView: View {
    @ObservedObject var store: FeatureStore
    let steward: String
    let tests: [String: ConnectionTest]

    var body: some View {
        let channels = PeopleChannels(events: store.events, steward: steward, now: store.now)
            .channels
        VStack(alignment: .leading, spacing: AryaSpace.s5) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(channels) { channel in
                    row(channel)
                    AryaHairline()
                }
            }
            recent
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Channels")
    }

    /// Every person's newest messages across channels, newest first.
    private var recent: some View {
        let directory = PeopleDirectory(events: store.events, steward: steward)
        let items = directory.people.flatMap { person in
            PeopleThread(events: store.events, steward: steward, person: person.id).entries
                .filter { $0.action != "report" }
                .map { (person: person, entry: $0) }
        }
        .sorted { $0.entry.at > $1.entry.at }.prefix(14)
        return VStack(alignment: .leading, spacing: AryaSpace.s1) {
            Text("RECENT MESSAGES").aryaText(AryaFont.label, AryaColor.inkFaint)
            ForEach(Array(items), id: \.entry.id) { item in
                HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s3) {
                    Text(item.person.via ?? "inbox")
                        .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                        .frame(width: 48, alignment: .leading)
                    Text(item.entry.inbound ? item.person.name : "→ " + item.person.name)
                        .aryaText(
                            AryaFont.monoSmall,
                            item.entry.inbound ? AryaColor.inkMuted : AryaColor.accent
                        )
                        .frame(width: 72, alignment: .leading)
                    Text(PeopleThreadText.tag(item.entry) ?? "")
                        .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                        .frame(width: 64, alignment: .leading)
                    Text(item.entry.text).aryaText(AryaFont.caption, AryaColor.ink).lineLimit(1)
                    Spacer(minLength: AryaSpace.s3)
                    Text(FeatureTime.relative(item.entry.at, now: store.now))
                        .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                }
                .frame(height: 20)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func row(_ channel: PeopleChannels.Channel) -> some View {
        let status = PeopleChannelsText.status(channel, test: tests[channel.id])
        return VStack(alignment: .leading, spacing: AryaSpace.s1) {
            HStack(alignment: .center, spacing: AryaSpace.s3) {
                Text(channel.id).aryaText(AryaFont.monoStrong, AryaColor.ink)
                    .frame(minWidth: 72, alignment: .leading)
                Text(channel.relay ? "relay" : "local inbox")
                    .aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                HStack(spacing: AryaSpace.s1) {
                    StatusDot(status.ok ? .passed : status.warn ? .waiting : .failed)
                    Text(status.text).aryaText(AryaFont.monoSmall, status.color)
                }
                Spacer(minLength: AryaSpace.s3)
                Sparkline(channel.daily)
                    .accessibilityLabel("Messages per day this week")
                Text("\(channel.inbound) in · \(channel.outbound) out · 7d")
                    .aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                    .frame(minWidth: 136, alignment: .trailing)
            }
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s4) {
                Text(channel.people.isEmpty ? "no one yet" : channel.people.joined(separator: ", "))
                    .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                if let last = channel.last {
                    Text((last.from ?? "Steward") + ": " + last.text)
                        .aryaText(AryaFont.caption, AryaColor.inkMuted)
                    Spacer(minLength: 0)
                    Text(FeatureTime.relative(last.at, now: store.now))
                        .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                }
            }
            .lineLimit(1)
        }
        .padding(.vertical, AryaSpace.s2)
        .accessibilityElement(children: .combine)
    }
}

enum PeopleChannelsText {
    struct Status: Equatable {
        var text: String
        var ok: Bool
        var warn: Bool

        var color: Color {
            ok ? AryaColor.positive : warn ? AryaColor.inkMuted : AryaColor.negative
        }
    }

    /// The local inbox is always up; a relay is up when bound and its last test passed.
    static func status(_ channel: PeopleChannels.Channel, test: ConnectionTest?) -> Status {
        guard channel.relay else { return Status(text: "local", ok: true, warn: false) }
        guard channel.bound else {
            return Status(text: "not in the charter", ok: false, warn: false)
        }
        guard let test else { return Status(text: "bound · not tested", ok: false, warn: true) }
        if test.complete { return Status(text: "bound · test passed", ok: true, warn: false) }
        return Status(text: "bound · test failed", ok: false, warn: false)
    }
}
