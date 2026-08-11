import Foundation

/// Decides whether a reply is worth a `WKWebView`.
///
/// # Why there is a fast path at all
///
/// Rendering the transcript through the shared Rust pipeline means an HTML
/// engine per bubble. Measured on the development machine, warm, over 40 views:
/// **18.6 ms** to create and load one `WKWebView` and roughly 0.7 MB resident
/// each. The transcript is a `LazyVStack`, so only visible bubbles realize — but
/// a scroll that realizes ten would still spend ~190 ms building browsers, and
/// most assistant replies are a sentence or two of prose with no markup in them.
/// KDE hit the same shape of problem from the other direction (Qt's
/// `MarkdownText` stalling on long lists) and reached for the same answer.
///
/// # The bias
///
/// The two failure modes are not symmetric. A false *rich* costs ~18 ms and
/// looks identical to the user. A false *plain* shows them literal `**stars**`
/// and unrendered table pipes. So every ambiguous case resolves to rich, and the
/// plain path is reserved for text that provably contains no markup signal.
///
/// This is a syntax check, not a parse: it asks "could a CommonMark parser
/// possibly do something here", never "what would it do".
public enum RichMarkupPolicy {

    /// Characters that only appear in prose by accident, and always mean
    /// something to a Markdown parser when they appear on purpose.
    ///
    /// `-` is deliberately absent — hyphens and dashes are ordinary punctuation,
    /// so a leading `- ` is detected per-line instead. `(` / `)` are absent for
    /// the same reason; a link needs a preceding `]`, which is in the set.
    private static let inlineMarkers: Set<Character> = [
        "*",  // emphasis / bullets
        "_",  // emphasis
        "`",  // code
        "~",  // strikethrough
        "|",  // tables
        "#",  // headings
        ">",  // blockquotes
        "[", "]",  // links, images, task-list boxes
        "<",  // raw HTML (which the sanitizer must get a look at)
        "\\",  // escapes
    ]

    /// Whether `text` should be rendered through the webview pipeline rather than
    /// as a plain SwiftUI `Text`.
    public static func needsRichRendering(_ text: String) -> Bool {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        if text.contains(where: inlineMarkers.contains) {
            return true
        }
        // Line-anchored block constructs, which the character scan above cannot
        // see because their markers are ordinary punctuation in prose.
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .contains(where: startsABlock)
    }

    /// Whether a single line opens a Markdown block whose marker is otherwise
    /// unremarkable punctuation: a `-`/`+` bullet, an ordered-list number, or an
    /// indented code block.
    private static func startsABlock(_ line: Substring) -> Bool {
        // An indented code block: four spaces or a tab, then content.
        if line.hasPrefix("    ") || line.hasPrefix("\t") {
            return !line.trimmingCharacters(in: .whitespaces).isEmpty
        }

        // Up to three leading spaces still counts as the same block level.
        let body = line.drop(while: { $0 == " " })
        guard line.count - body.count <= 3, let first = body.first else { return false }

        // A `---` thematic break, or a `---` / `===` setext heading underline.
        // These are the only block markers made entirely of characters that are
        // also ordinary punctuation, so they need their own case.
        if first == "-" || first == "=" {
            let ruleBody = body.filter { $0 != " " }
            if ruleBody.count >= 3, ruleBody.allSatisfy({ $0 == first }) {
                return true
            }
        }

        // `- ` / `+ ` bullets. The trailing space is what separates a list from
        // hyphenated prose ("well-known") or an arithmetic dash.
        if first == "-" || first == "+" {
            return body.dropFirst().first == " "
        }

        // `1. ` / `1) ` ordered items. Requires the delimiter *and* the space, so
        // "I counted 3 items" stays plain.
        guard first.isNumber else { return false }
        let afterDigits = body.drop(while: \.isNumber)
        guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" else {
            return false
        }
        return afterDigits.dropFirst().first == " "
    }
}
