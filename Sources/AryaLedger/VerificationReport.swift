/// A stable, human-readable rendering of a `LedgerVerification` for the CLI's
/// `ledger verify` and the app's verify button.
///
/// The text is a fixed format: a one-line `headline`, then `details` lines of the form
/// `label: value` in a fixed order. Numbers are plain integers and nothing depends on the
/// locale, the clock, or the machine, so the same ledger always renders the same bytes and
/// tests can compare whole reports.
public struct LedgerVerificationReport: Hashable, Sendable {
    public var ok: Bool
    /// One line: `ledger ok: …` or `ledger broken at seq N: …`.
    public var headline: String
    /// Labeled lines under the headline, in a fixed order.
    public var details: [String]

    /// The headline followed by the details.
    public var lines: [String] { [headline] + details }

    /// `lines` joined with newlines, without a trailing newline.
    public var text: String { lines.joined(separator: "\n") }
}

extension LedgerVerification {
    /// The report for this verdict.
    public var report: LedgerVerificationReport {
        let events = "\(self.events) \(self.events == 1 ? "event" : "events")"
        let files = "\(segments) \(segments == 1 ? "segment" : "segments")"
        guard let failure, let seq = firstBadSeq else {
            return LedgerVerificationReport(
                ok: true, headline: "ledger ok: \(events) in \(files)",
                details: ["head: \(head)"])
        }
        let location = failure.location
        if case .unanchored = failure.issue {
            return LedgerVerificationReport(
                ok: false, headline: "ledger unanchored: \(failure.issue)",
                details: [
                    "where: \(location.segment) line \(location.line), byte \(location.offset)",
                    "verified: \(events) from seq \(firstSeq), in \(files); head \(head)",
                    "meaning: \(failure.issue.meaning)",
                    "next: \(failure.issue.nextStep)",
                ])
        }
        return LedgerVerificationReport(
            ok: false, headline: "ledger broken at seq \(seq): \(failure.issue)",
            details: [
                "where: \(location.segment) line \(location.line), byte \(location.offset)",
                "verified: \(events) before it, in \(files); last good head \(head)",
                "meaning: \(failure.issue.meaning)",
                "next: \(failure.issue.nextStep)",
            ])
    }
}

extension LedgerVerification.Issue {
    /// What this kind of failure says about the ledger, in one sentence.
    public var meaning: String {
        switch self {
        case .line(.hashMismatch):
            return "the line's bytes changed after it was written."
        case .line(.missingHashSuffix), .line(.tooShort):
            return "the line is not a sealed ledger line."
        case .line(.badEnvelope):
            return "the line is sealed but its envelope does not decode."
        case .seqGap:
            return "lines are missing, duplicated, or out of order."
        case .prevMismatch:
            return "the hash chain is broken: a line was removed, inserted, or replaced."
        case .torn(repairable: true):
            return "an append was interrupted before its newline."
        case .torn(repairable: false):
            return "a segment other than the newest ends in the middle of a line."
        case .badCheckpoint(_, .unknownKey), .badCheckpoint(_, .badSignature),
            .badCheckpoint(_, .malformed):
            return "a checkpoint is not signed by a key this ledger trusts."
        case .badCheckpoint:
            return "a signed checkpoint does not match the events or segments it names."
        case .unanchored:
            return "older segments are gone and no signed checkpoint vouches for what they held."
        }
    }

    /// What to do about it, in one sentence.
    public var nextStep: String {
        switch self {
        case .torn(repairable: true):
            return "nothing; the next write moves the partial bytes to a blob and records "
                + "system.repair."
        case .badCheckpoint:
            return "do not compact with this checkpoint; find out who wrote it, then record a "
                + "fresh one."
        case .unanchored:
            return "restore the archived segments or the checkpoint that covers them; history "
                + "before the first live event cannot be trusted until then."
        default:
            return "stop writing to this home and restore the named segment from a backup; "
                + "events after the break cannot be trusted."
        }
    }
}
