import CAdeleCore
import Foundation

/// Swift face of the core's markdown surface.
///
/// The reducer deliberately ships raw Markdown and treats presentation as the
/// client's job. Rendering it is not just formatting, though: assistant output
/// is **untrusted** (gtk#25), so turning it into HTML for a `WKWebView` crosses
/// a trust boundary. The shared Rust crate `adele-markdown` owns both halves of
/// the defence — `ammonia` sanitization of the rendered HTML, and a page whose
/// CSP `script-src` is pinned to the SHA-256 of the one script it ships — and
/// this type is only the marshalling.
///
/// Nothing here parses, escapes, or filters markup. That is the point: adele-gtk
/// and adele-mac run the same security-reviewed code instead of two
/// implementations that drift.
///
/// Unlike the rest of `AdeleCore`, these calls are synchronous. Rendering is
/// pure and the caller needs the string in hand to feed its webview.
public enum AdeleMarkdown {

    /// Render untrusted markdown to a **sanitized HTML fragment**, for streaming
    /// into a page that is already loaded.
    public static func fragment(_ markdown: String) -> String {
        take(markdown.withCString { adele_core_render_markdown($0) })
    }

    /// Render untrusted markdown to a **complete, CSP-locked page** for one
    /// message bubble. Load this once with a `nil` base URL; stream later
    /// updates with ``fragment(_:)`` plus ``setContentCall(_:)``, which leaves
    /// the page (and therefore its pinned script hash) untouched.
    public static func document(_ markdown: String) -> String {
        take(markdown.withCString { adele_core_render_markdown_document($0) })
    }

    /// Name of the script-message handler the bubble page posts its pixel height
    /// to. Read from the core rather than hardcoded: an embedded engine does not
    /// self-size inside a SwiftUI stack, so a misnamed handler is a bubble
    /// frozen at its initial height with no error anywhere.
    public static let heightHandlerName: String = borrow(
        adele_core_markdown_height_handler_name())

    /// Name of the page's in-place content-swap function, from the core for the
    /// same reason.
    public static let setContentFunction: String = borrow(
        adele_core_markdown_set_content_function())

    /// Build the JavaScript the host evaluates to swap new content into a loaded
    /// bubble page.
    ///
    /// `fragmentHTML` must already have been through ``fragment(_:)``.
    public static func setContentCall(_ fragmentHTML: String) -> String {
        "\(setContentFunction)(\(jsStringLiteral(fragmentHTML)))"
    }

    /// Encode a string as a JavaScript string literal, quotes included.
    ///
    /// Sanitized HTML is inert as *markup* but is still attacker-influenced
    /// *text*, and this is the one hop the page's CSP cannot protect:
    /// host-evaluated script is exempt from CSP by design (that exemption is
    /// exactly what lets a streaming reply update without reloading the page and
    /// re-deriving its hash). So the escaping here is the whole guarantee that
    /// content stays content.
    ///
    /// JSON is the encoding because it is a strict subset of JS string syntax
    /// *and* independently verifiable — the spec round-trips it through
    /// `JSONDecoder`. Two additions on top of JSON:
    ///
    /// - `U+2028` / `U+2029` are literal line terminators in pre-ES2019
    ///   grammars and JSON does not escape them.
    /// - `</script>` is escaped even though the call is evaluated rather than
    ///   injected into a `<script>` element, so moving the injection site later
    ///   cannot silently open a hole.
    static func jsStringLiteral(_ value: String) -> String {
        // `JSONSerialization` needs a top-level container, so encode a
        // one-element array and unwrap the brackets.
        // `withoutEscapingSlashes` so the `</script` guard below is real rather
        // than shadowed by JSON's optional solidus escaping.
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: [value], options: [.withoutEscapingSlashes]),
            let wrapped = String(data: data, encoding: .utf8),
            wrapped.count >= 2
        else {
            // Unreachable for a `String`, but a literal that is merely empty
            // beats one that is malformed.
            return "\"\""
        }
        return String(wrapped.dropFirst().dropLast())
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            .replacingOccurrences(of: "</script", with: "<\\/script")
    }

    /// Copy a core-allocated C string into Swift and release it through the
    /// core's own free — the allocators are not required to match.
    private static func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
        guard let pointer else { return "" }
        defer { adele_core_string_free(pointer) }
        return String(cString: pointer)
    }

    /// Copy a `'static` core string. Never freed — the core owns it.
    private static func borrow(_ pointer: UnsafePointer<CChar>?) -> String {
        pointer.map { String(cString: $0) } ?? ""
    }
}
