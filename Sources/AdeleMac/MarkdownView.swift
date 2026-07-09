import SwiftUI

/// A lightweight, dependency-free Markdown renderer for assistant replies.
///
/// The reducer deliberately ships raw Markdown text (presentation is the client's
/// job — the GTK client renders it to HTML in a WebView). Here we render it with
/// native SwiftUI: block structure (headings, fenced code, lists, blockquotes,
/// paragraphs) is parsed line-by-line, and inline spans (bold/italic/code/links)
/// go through `AttributedString(markdown:)`. It tolerates partial input, so a
/// streaming reply with an as-yet-unclosed code fence still renders sensibly.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                block.view
            }
        }
    }
}

enum MarkdownBlock {
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(language: String?, code: String)
    case bulletList([String])
    case orderedList([(marker: String, text: String)])
    case quote([String])

    @ViewBuilder var view: some View {
        switch self {
        case .paragraph(let s):
            Self.inlineText(s)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level, let s):
            Self.inlineText(s)
                .font(Self.headingFont(level))
                .fixedSize(horizontal: false, vertical: true)

        case .code(_, let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Self.inlineText(item).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker).foregroundStyle(.secondary).monospacedDigit()
                        Self.inlineText(item.text).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .quote(let lines):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(.secondary).frame(width: 3)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Self.inlineText(line).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.weight(.bold)
        case 2: return .title3.weight(.semibold)
        default: return .headline
        }
    }

    /// Render inline Markdown (bold/italic/code/links) to a `Text`, falling back
    /// to the raw string if it doesn't parse.
    static func inlineText(_ s: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(s)
    }

    // MARK: - Block parser

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0

        func flushParagraph(_ buffer: inout [String]) {
            guard !buffer.isEmpty else { return }
            blocks.append(.paragraph(buffer.joined(separator: "\n")))
            buffer.removeAll()
        }

        var paragraph: [String] = []

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block.
            if trimmed.hasPrefix("```") {
                flushParagraph(&paragraph)
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                i += 1  // consume closing fence (or run off the end for partial input)
                blocks.append(.code(language: language.isEmpty ? nil : language,
                                    code: code.joined(separator: "\n")))
                continue
            }

            // Blank line ends a paragraph.
            if trimmed.isEmpty {
                flushParagraph(&paragraph)
                i += 1
                continue
            }

            // ATX heading.
            if let heading = Self.parseHeading(trimmed) {
                flushParagraph(&paragraph)
                blocks.append(heading)
                i += 1
                continue
            }

            // Blockquote (consecutive `>` lines).
            if trimmed.hasPrefix(">") {
                flushParagraph(&paragraph)
                var quoted: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    quoted.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quoted))
                continue
            }

            // Bullet list.
            if Self.isBullet(trimmed) {
                flushParagraph(&paragraph)
                var items: [String] = []
                while i < lines.count, Self.isBullet(lines[i].trimmingCharacters(in: .whitespaces)) {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    items.append(String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.bulletList(items))
                continue
            }

            // Ordered list.
            if Self.orderedMarker(trimmed) != nil {
                flushParagraph(&paragraph)
                var items: [(String, String)] = []
                while i < lines.count, let marker = Self.orderedMarker(lines[i].trimmingCharacters(in: .whitespaces)) {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    let rest = String(t.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                    items.append((marker, rest))
                    i += 1
                }
                blocks.append(.orderedList(items))
                continue
            }

            // Otherwise, accumulate into the current paragraph.
            paragraph.append(line)
            i += 1
        }
        flushParagraph(&paragraph)
        return blocks
    }

    private static func parseHeading(_ line: String) -> MarkdownBlock? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil }
        return .heading(level: level, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isBullet(_ line: String) -> Bool {
        guard line.count >= 2 else { return false }
        let prefix = line.prefix(2)
        return prefix == "- " || prefix == "* " || prefix == "+ "
    }

    /// Returns the marker (e.g. "1.") if the line begins an ordered-list item.
    private static func orderedMarker(_ line: String) -> String? {
        var digits = ""
        for ch in line {
            if ch.isNumber { digits.append(ch) } else { break }
        }
        guard !digits.isEmpty else { return nil }
        let after = line.dropFirst(digits.count)
        guard let dot = after.first, dot == "." || dot == ")",
              after.dropFirst().first == " " else { return nil }
        return digits + String(dot)
    }
}
