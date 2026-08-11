import AdeleCore
import AppKit
import SwiftUI
import WebKit

/// Renders an assistant reply in the transcript.
///
/// The reducer ships raw Markdown and treats presentation as the client's job.
/// Replies routinely use the whole CommonMark set — tables, nested and task
/// lists, blockquotes, fenced code — so the rich path is a `WKWebView` fed by
/// the shared Rust pipeline (`AdeleMarkdown`), the same sanitizer and
/// CSP-pinned page adele-gtk renders through. Assistant output is untrusted
/// (gtk#25); reusing that pipeline is the security boundary, not a shortcut.
///
/// Plain prose skips the webview entirely — see ``RichMarkupPolicy`` for the
/// measurement behind that.
struct MarkdownView: View {
    let text: String

    var body: some View {
        if RichMarkupPolicy.needsRichRendering(text) {
            RichMarkupView(text: text)
        } else {
            Text(text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Rich path

/// A message body rendered in an embedded engine, sized to its content.
///
/// A `WKWebView` does not self-size inside a SwiftUI stack — left alone it takes
/// whatever it is given and the transcript layout collapses — so the page posts
/// `document.body.scrollHeight` back over the script bridge and that number
/// drives the frame.
private struct RichMarkupView: View {
    let text: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var height: CGFloat

    init(text: String) {
        self.text = text
        // Start at the last height this exact content measured, so a bubble
        // scrolled out of the LazyVStack and back does not snap to a stub height
        // and shove the transcript around while it re-measures.
        _height = State(initialValue: MarkupHeightCache.shared.height(for: text) ?? 20)
    }

    var body: some View {
        MarkupWebView(markdown: text, colorScheme: colorScheme, height: $height)
            .frame(height: height)
            // The webview's text is invisible to the accessibility tree from out
            // here; expose the source so VoiceOver still reads the reply.
            .accessibilityElement()
            .accessibilityLabel(text)
    }
}

/// Remembers measured bubble heights so re-realized rows start at the right size.
@MainActor
private final class MarkupHeightCache {
    static let shared = MarkupHeightCache()

    private let store = NSCache<NSString, NSNumber>()

    private init() {
        // Bounded: this is an optimization, and a miss costs one reflow.
        store.countLimit = 256
    }

    func height(for markdown: String) -> CGFloat? {
        store.object(forKey: markdown as NSString).map { CGFloat($0.doubleValue) }
    }

    func record(_ height: CGFloat, for markdown: String) {
        store.setObject(NSNumber(value: Double(height)), forKey: markdown as NSString)
    }
}

// MARK: - The webview

private struct MarkupWebView: NSViewRepresentable {
    let markdown: String
    let colorScheme: ColorScheme
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let web = BubbleWebView(frame: .zero, configuration: MarkupBridge.shared.configuration)
        web.navigationDelegate = context.coordinator
        web.allowsMagnification = false
        web.allowsBackForwardNavigationGestures = false
        web.setBubbleBackgroundTransparent()
        apply(colorScheme, to: web)

        context.coordinator.markdown = markdown
        let binding = $height
        MarkupBridge.shared.register(web) { [weak web] reported in
            guard let web, let text = MarkupBridge.shared.markdown(for: web) else { return }
            MarkupHeightCache.shared.record(reported, for: text)
            // Only move the binding when the height actually changed; SwiftUI
            // would otherwise re-lay-out on every identical report.
            if abs(binding.wrappedValue - reported) > 0.5 {
                binding.wrappedValue = reported
            }
        }
        MarkupBridge.shared.setMarkdown(markdown, for: web)

        // The first paint carries its content inline, so a bubble never flashes
        // empty before its first update lands.
        web.loadHTMLString(AdeleMarkdown.document(markdown), baseURL: nil)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        apply(colorScheme, to: web)
        MarkupBridge.shared.setMarkdown(markdown, for: web)
        context.coordinator.update(markdown, in: web)
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        MarkupBridge.shared.unregister(web)
    }

    /// Drive `prefers-color-scheme` inside the page from the SwiftUI environment.
    ///
    /// Setting the view's `appearance` rather than reading `NSApp` directly means
    /// this follows a `preferredColorScheme` override as well as the system, and
    /// WebKit re-evaluates the media query live when it changes.
    private func apply(_ scheme: ColorScheme, to web: WKWebView) {
        let name: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
        if web.appearance?.name != name {
            web.appearance = NSAppearance(named: name)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        /// The markdown currently reflected in the page (or queued for it).
        var markdown: String = ""
        private var isLoaded = false
        private var pending: String?

        /// Push new content into an already-loaded page.
        ///
        /// This is the streaming path, and it deliberately does **not** reload:
        /// a reload flickers, drops the selection, and resets scroll. Measured
        /// here, an in-place swap is 0.62 ms against 1.80 ms for a full document
        /// load — and only the swap preserves what the user is looking at.
        func update(_ next: String, in web: WKWebView) {
            guard next != markdown else { return }
            markdown = next
            guard isLoaded else {
                pending = next
                return
            }
            swapContent(next, in: web)
        }

        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            if let queued = pending {
                pending = nil
                swapContent(queued, in: web)
            }
        }

        private func swapContent(_ next: String, in web: WKWebView) {
            web.evaluateJavaScript(AdeleMarkdown.setContentCall(AdeleMarkdown.fragment(next)))
        }

        /// Links open in the user's browser, never in the bubble.
        ///
        /// A reply is untrusted, so the page gets exactly one navigation — the
        /// host's own `loadHTMLString`, which lands on `about:blank`. Everything
        /// else is cancelled; a link the user actually clicked is then handed to
        /// the system, and only for schemes worth handing over.
        @MainActor
        func webView(
            _ web: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            if navigationAction.navigationType == .other, url.scheme == "about" {
                return .allow
            }
            if navigationAction.navigationType == .linkActivated,
                let scheme = url.scheme?.lowercased(),
                ["http", "https", "mailto"].contains(scheme)
            {
                NSWorkspace.shared.open(url)
            }
            return .cancel
        }
    }
}

/// The `WKWebView` subclass a bubble uses.
private final class BubbleWebView: WKWebView {
    /// Let the transcript scroll when the pointer is over a bubble.
    ///
    /// The bubble is sized to its content and never scrolls vertically, so a
    /// vertical wheel event belongs to the enclosing `ScrollView`. Horizontal
    /// ones stay here — that is how a wide table or code block scrolls inside
    /// its own bubble instead of stretching the transcript.
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

extension WKWebView {
    /// Stop the engine painting its own background, so the native bubble's fill
    /// and rounded corners show through instead of a white rectangle.
    ///
    /// `underPageBackgroundColor` is the public spelling but does not do this —
    /// measured, it leaves the snapshot fully opaque. The KVC-settable
    /// `drawsBackground` does. Guarded with `responds(to:)` because an unknown
    /// key raises an Objective-C exception Swift cannot catch: losing
    /// transparency is a cosmetic regression, crashing is not.
    fileprivate func setBubbleBackgroundTransparent() {
        guard responds(to: Selector(("setDrawsBackground:"))) else { return }
        setValue(false, forKey: "drawsBackground")
    }
}

// MARK: - Host/page bridge

/// The single script-message handler every bubble page reports its height to.
///
/// One shared `WKWebViewConfiguration` across all bubbles rather than one each:
/// measured over 40 views, a fresh configuration per view costs 59.4 ms to
/// create and load, a shared one 20.9 ms and ~35% less memory. (The deprecated
/// `WKProcessPool` buys the same win; sharing the configuration buys it without
/// the deprecated API.) One configuration means one handler for every page, so
/// it routes on `message.webView`.
@MainActor
private final class MarkupBridge: NSObject, WKScriptMessageHandler {
    static let shared = MarkupBridge()

    let configuration: WKWebViewConfiguration

    private var heightSinks: [ObjectIdentifier: (CGFloat) -> Void] = [:]
    private var markdownByView: [ObjectIdentifier: String] = [:]

    override private init() {
        configuration = WKWebViewConfiguration()
        // Nothing a bubble does should touch disk: the page has no network and
        // no storage, and an untrusted reply must not leave a trace behind.
        configuration.websiteDataStore = .nonPersistent()
        super.init()
        configuration.userContentController.add(self, name: AdeleMarkdown.heightHandlerName)
    }

    func register(_ web: WKWebView, onHeight: @escaping (CGFloat) -> Void) {
        heightSinks[ObjectIdentifier(web)] = onHeight
    }

    func unregister(_ web: WKWebView) {
        let key = ObjectIdentifier(web)
        heightSinks[key] = nil
        markdownByView[key] = nil
    }

    func setMarkdown(_ markdown: String, for web: WKWebView) {
        markdownByView[ObjectIdentifier(web)] = markdown
    }

    func markdown(for web: WKWebView) -> String? {
        markdownByView[ObjectIdentifier(web)]
    }

    nonisolated func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            guard let web = message.webView,
                let value = message.body as? NSNumber,
                let sink = heightSinks[ObjectIdentifier(web)]
            else { return }
            sink(CGFloat(value.doubleValue))
        }
    }
}
