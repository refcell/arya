import AppKit
import SwiftUI

/// `sunken` fill, medium radius, 12 pt padding, `mono`/`ink`. Lines scroll, never wrap.
/// A tertiary Copy button appears on hover at the top right.
public struct CodeBlock: View {
    let text: String
    @AryaState private var isHovering = false

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        ScrollView(.horizontal) {
            Text(text)
                .aryaText(AryaFont.mono, AryaColor.ink)
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
                .padding(AryaSpace.s3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AryaColor.sunken, in: RoundedRectangle(cornerRadius: AryaRadius.medium))
        .overlay(alignment: .topTrailing) {
            if isHovering {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.aryaTertiary)
                .padding(AryaSpace.s1)
            }
        }
        .onHover { isHovering = $0 }
    }
}

/// One line of a unified diff.
public struct DiffLine: Hashable, Sendable {
    public enum Kind: Sendable { case context, added, removed, hunk, header }

    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }

    /// Classifies each line of unified diff text.
    public static func parse(_ diff: String) -> [DiffLine] {
        diff.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = String(raw)
            if line.hasPrefix("+++") || line.hasPrefix("---") {
                return DiffLine(kind: .header, text: line)
            }
            if line.hasPrefix("@@") { return DiffLine(kind: .hunk, text: line) }
            if line.hasPrefix("+") { return DiffLine(kind: .added, text: line) }
            if line.hasPrefix("-") { return DiffLine(kind: .removed, text: line) }
            return DiffLine(kind: .context, text: line)
        }
    }

    /// Text color token. The monochrome rule holds: only the +/- marks carry status color.
    public var textToken: AryaColorToken {
        switch kind {
        case .context, .added, .removed: .ink
        case .hunk, .header: .inkMuted
        }
    }

    /// The color token of the leading mark, if the line has one.
    public var markToken: AryaColorToken? {
        switch kind {
        case .added: .positive
        case .removed: .negative
        default: nil
        }
    }
}

/// A code block for unified diffs: `+` and `-` marks in `positive` and `negative` text.
public struct DiffBlock: View {
    let lines: [DiffLine]

    public init(_ diff: String) {
        self.lines = DiffLine.parse(diff)
    }

    public var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    row(line)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .textSelection(.enabled)
            .padding(AryaSpace.s3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AryaColor.sunken, in: RoundedRectangle(cornerRadius: AryaRadius.medium))
    }

    private func row(_ line: DiffLine) -> some View {
        let mark = line.markToken
        let body = mark == nil ? line.text : String(line.text.dropFirst())
        return HStack(spacing: 0) {
            if let mark {
                Text(String(line.text.prefix(1))).aryaText(AryaFont.mono, mark.color)
            }
            Text(body.isEmpty ? " " : body).aryaText(AryaFont.mono, line.textToken.color)
        }
    }
}
