import Testing
@testable import AdeleCore

/// Spec: the measured plain-text fast path.
///
/// A `WKWebView` per bubble is not free. Measured on this machine (macOS 15,
/// release-mode WebKit, 40 views, warm): **18.6 ms** to create and load one,
/// and ~0.7 MB resident each — against effectively zero for a SwiftUI `Text`.
/// A transcript scroll that realizes ten bubbles would otherwise spend ~190 ms
/// building browsers to render prose that has no markup in it, which is the
/// same class of problem KDE hit with Qt's `MarkdownText` on long lists.
///
/// So: a reply gets the webview only when it contains something the webview can
/// actually render differently. The policy is deliberately **biased toward
/// rich** — a false "rich" costs 18 ms, a false "plain" shows the user literal
/// `**asterisks**`, so every ambiguous case must resolve to rich.
@Suite struct RichMarkupPolicyTests {

    // MARK: - Plain prose takes the fast path

    @Test(arguments: [
        "Sure, I can help with that.",
        "The meeting is at 3pm tomorrow.",
        "I found 4 results. Let me know if you want more detail.",
        "Done — the file is saved.",
        "It costs $4.50 (including tax).",
        "Yes! That works. Why not?",
        "Line one\nLine two\nLine three",
    ])
    func plainProseSkipsTheWebview(_ text: String) {
        #expect(!RichMarkupPolicy.needsRichRendering(text))
    }

    @Test func emptyAndWhitespaceSkipTheWebview() {
        #expect(!RichMarkupPolicy.needsRichRendering(""))
        #expect(!RichMarkupPolicy.needsRichRendering("   \n  "))
    }

    // MARK: - Anything with markup gets the webview

    @Test(arguments: [
        "**bold**",
        "*italic*",
        "_underscore emphasis_",
        "~~struck~~",
        "`inline code`",
        "```\nfenced\n```",
        "# Heading",
        "### Deeper heading",
        "> a quote",
        "| a | b |\n|---|---|\n| 1 | 2 |",
        "[a link](https://example.com)",
        "![an image](https://example.com/x.png)",
        "- bullet one\n- bullet two",
        "* star bullet",
        "+ plus bullet",
        "1. first\n2. second",
        "1) paren ordered",
        "  - indented bullet",
        "Some prose\n\n    indented code block",
        "Some prose\n\n\ttab-indented code",
        "---",
        "text with <b>raw html</b>",
        "an escaped \\* star",
    ])
    func markupGetsTheWebview(_ text: String) {
        #expect(RichMarkupPolicy.needsRichRendering(text))
    }

    // MARK: - The bias, spelled out

    @Test func hyphenatedProseIsNotMistakenForAList() {
        // A leading list marker needs the trailing space; "well-known" must not
        // drag a whole reply into the webview for nothing.
        #expect(!RichMarkupPolicy.needsRichRendering("This is a well-known trade-off."))
    }

    @Test func aDashOnlyCountsAsAListWhenItLeadsALine() {
        #expect(!RichMarkupPolicy.needsRichRendering("five - three equals two"))
        #expect(RichMarkupPolicy.needsRichRendering("five\n- three"))
    }

    @Test func aTrailingParagraphNumberIsNotAnOrderedList() {
        #expect(!RichMarkupPolicy.needsRichRendering("I counted 3 items in total."))
        #expect(RichMarkupPolicy.needsRichRendering("3. the third item"))
    }

    @Test func anAmbiguousLoneAsteriskStillGoesRich() {
        // Cheaper to render an unmatched asterisk through the real parser than
        // to guess wrong about whether it opens emphasis.
        #expect(RichMarkupPolicy.needsRichRendering("2 * 3 = 6"))
    }
}
