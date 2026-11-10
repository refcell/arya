import Arya
import AryaDesign
import SwiftUI

/// The Report section on People: who gets the steward's periodic report and when, the digest
/// as it would go out now, Send now, and a form whose result is a gated charter proposal.
struct PeopleReportSection: View {
    @ObservedObject var store: FeatureStore
    @ObservedObject var reports: ReportDigestStore
    let directory: PeopleDirectory
    let read: @Sendable (String) async throws -> ReportDigest
    let propose: (CharterProposal?) -> Void

    @AryaState private var editing = false
    @AryaState private var draft = ReportDraft()

    var body: some View {
        let report = PeopleReport(events: store.events, steward: directory.steward)
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s3) {
                Text("REPORT").aryaText(AryaFont.label, AryaColor.inkFaint)
                Text(report.schedule(names: name))
                    .aryaText(
                        AryaFont.caption, report.configured ? AryaColor.ink : AryaColor.inkMuted)
                Spacer()
                if !editing, report.live != nil {
                    Button(report.configured ? "Edit" : "Set up") {
                        draft = report.configured ? ReportDraft(report) : ReportDraft()
                        if !report.configured { draft.to = directory.people.prefix(1).map(\.id) }
                        editing = true
                    }
                    .buttonStyle(.aryaTertiary)
                }
                if report.configured, !editing {
                    // The screen's one primary: the report goes out now as a report run, so a
                    // relayed send meets the charter's policy and may wait for approval.
                    Button("Send now") {
                        Task {
                            if await store.perform(.sendReport(steward: directory.steward)) {
                                reports.load(directory.steward, read: read)
                            }
                        }
                    }
                    .buttonStyle(.aryaPrimary)
                    .help("Send it now; sends through a relay follow the charter's policy.")
                }
            }
            if report.configured {
                HStack(spacing: AryaSpace.s5) {
                    if let next = report.next(after: store.now) {
                        fact("Next", FeatureTime.absolute(next, timeZone: utc))
                    }
                    fact(
                        "Last sent",
                        report.lastSent.map { FeatureTime.phrase($0, now: store.now) } ?? "never")
                }
            }
            if editing { form(report) }
            preview
        }
        .padding(.vertical, AryaSpace.s2)
        .onAppear { reports.load(directory.steward, read: read) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Report")
    }

    @ViewBuilder private var preview: some View {
        if let digest = reports.digests[directory.steward] {
            VStack(alignment: .leading, spacing: 2) {
                Text(digest.configured ? "NEXT REPORT" : "PREVIEW")
                    .aryaText(AryaFont.label, AryaColor.inkFaint)
                ForEach(Array(digest.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).aryaText(AryaFont.monoSmall, AryaColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(AryaSpace.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AryaColor.sunken, in: RoundedRectangle(cornerRadius: AryaRadius.small))
        } else if let problem = reports.problems[directory.steward] {
            Text(problem).aryaText(AryaFont.caption, AryaColor.inkFaint)
        }
    }

    private func form(_ report: PeopleReport) -> some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            row("Cadence") {
                AryaSegmented([("weekly", "Weekly"), ("daily", "Daily")], selection: draft.cadence)
                {
                    draft.cadence = $0
                }
            }
            if draft.cadence == "weekly" {
                row("Day") {
                    AryaSegmented(
                        PeopleReport.days.enumerated().map {
                            ($0.offset + 1, String($0.element.prefix(3)))
                        },
                        selection: draft.weekday
                    ) { draft.weekday = $0 }
                }
            }
            row("Hour") {
                CharterTextField(placeholder: "9", text: $draft.hour, mono: true)
                    .frame(width: 60)
                Text("UTC").aryaText(AryaFont.caption, AryaColor.inkFaint)
            }
            row("To") {
                ForEach(directory.people) { person in
                    let on = draft.to.contains(person.id)
                    Button((on ? "✓ " : "") + person.name) {
                        draft.toggle(person.id, order: directory.people.map(\.id))
                    }
                    .buttonStyle(.aryaSecondary)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            ForEach(draft.issues, id: \.self) {
                Text($0).aryaText(AryaFont.caption, AryaColor.warning)
            }
            HStack(spacing: AryaSpace.s3) {
                Button("Propose") {
                    propose(report.proposal(draft))
                    editing = false
                }
                .buttonStyle(.aryaPrimary)
                .disabled(!draft.issues.isEmpty)
                Button("Cancel") { editing = false }.buttonStyle(.aryaTertiary)
                if report.configured {
                    Button("Stop sending") {
                        propose(report.stopProposal())
                        editing = false
                    }
                    .buttonStyle(.aryaTertiary)
                }
            }
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
        -> some View
    {
        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
            Text(title.uppercased()).aryaText(AryaFont.label, AryaColor.inkFaint)
                .frame(width: 80, alignment: .leading)
            content()
        }
    }

    private func name(_ id: String) -> String {
        directory.people.first { $0.id == id }?.name ?? PeopleDirectory.displayName(id)
    }

    private var utc: TimeZone { TimeZone(identifier: "UTC") ?? .current }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
            Text(label.uppercased()).aryaText(AryaFont.label, AryaColor.inkFaint)
            Text(value).aryaText(AryaFont.monoSmall, AryaColor.ink)
        }
    }
}

/// Past reports, newest first: when, who sent it, the subject, and each recipient with how it
/// reached them. Selecting one shows its text.
struct PeopleReportHistoryView: View {
    @ObservedObject var store: FeatureStore
    let directory: PeopleDirectory
    @AryaState private var open: String?

    var body: some View {
        let history = PeopleReportHistory(events: store.events, steward: directory.steward)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AryaSpace.s2) {
                Text("PAST REPORTS").aryaText(AryaFont.label, AryaColor.inkFaint)
                if !history.sent.isEmpty {
                    Text("\(history.sent.count)").aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                }
            }
            .padding(.bottom, AryaSpace.s1)
            if history.sent.isEmpty {
                Text("None sent yet.").aryaText(AryaFont.caption, AryaColor.inkFaint)
            }
            ForEach(history.sent) { sent in
                row(sent)
                if open == sent.id {
                    Text(sent.text).aryaText(AryaFont.monoSmall, AryaColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(AryaSpace.s3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            AryaColor.sunken, in: RoundedRectangle(cornerRadius: AryaRadius.small))
                }
                AryaHairline()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Past reports")
    }

    private func row(_ sent: PeopleReportHistory.Sent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s3) {
            DisclosureChevron(isExpanded: open == sent.id)
            Text(FeatureTime.relative(sent.at, now: store.now))
                .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                .frame(minWidth: 44, alignment: .leading)
            Text(sent.subject).aryaText(AryaFont.caption, AryaColor.ink).lineLimit(1)
            Spacer(minLength: AryaSpace.s3)
            ForEach(sent.recipients) { recipient in
                Text("\(recipient.name) · \(recipient.status.label)")
                    .aryaText(AryaFont.monoSmall, Self.color(recipient.status))
                    .lineLimit(1)
            }
            Text(sent.by.kind == .system ? "on schedule" : "sent by hand")
                .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
        }
        .frame(minHeight: AryaSize.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(AryaMotion.quick) { open = open == sent.id ? nil : sent.id }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    static func color(_ status: PeopleReportHistory.Status) -> Color {
        switch status {
        case .inbox, .sent: AryaColor.positive
        case .drafted, .waiting: AryaColor.warning
        case .denied, .failed: AryaColor.negative
        case .unknown: AryaColor.inkFaint
        }
    }
}
