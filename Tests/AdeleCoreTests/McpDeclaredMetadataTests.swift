import Foundation
import Testing

@testable import AdeleCore

/// Spec for the metadata an MCP server declares about itself (SEP-973): its
/// title, its description, and its website.
///
/// These three values are authored by whatever process the configuration points
/// at, so they are untrusted. `client-ui-common` sanitizes them, but only inside
/// `server_rows_with_builtins`, which this client does not call — adele-mac
/// decodes `list_mcp_servers` into its own `McpServerView` and builds its rows
/// in Swift. So the sanitizing is ported here too, and these tests state the
/// same rules the Rust module holds: whitespace collapsed, control characters
/// dropped, 200 characters maximum, and a website admitted only when its scheme
/// is `http` or `https`.
@Suite struct McpDeclaredMetadataTests {
    // MARK: Fixtures

    /// A daemon `McpServerView` carrying declared metadata. Decoded from JSON,
    /// because the type mirrors the wire form and has no memberwise init — which
    /// also keeps the fixture honest about the field names the daemon sends.
    private func daemonView(
        _ name: String,
        title: String? = nil,
        description: String? = nil,
        websiteURL: String? = nil
    ) throws -> McpServerView {
        var fields: [String: Any] = [
            "name": name,
            "command": "cmd",
            "args": [String](),
            "enabled": true,
            "status": "running",
            "tool_count": 0,
            "transport": "stdio",
            "target": "cmd",
        ]
        if let title { fields["title"] = title }
        if let description { fields["description"] = description }
        if let websiteURL { fields["website_url"] = websiteURL }
        let data = try JSONSerialization.data(withJSONObject: fields)
        return try JSONDecoder().decode(McpServerView.self, from: data)
    }

    private func row(
        _ name: String,
        title: String? = nil,
        description: String? = nil,
        websiteURL: String? = nil
    ) throws -> McpServerRow {
        let view = try daemonView(
            name, title: title, description: description, websiteURL: websiteURL)
        let rows = mcpServerRows(daemon: [view], client: [], builtins: [])
        return try #require(rows.first)
    }

    // MARK: The row heading

    /// A server that declared a title shows it as the row heading.
    @Test func aDeclaredTitleBecomesTheHeading() throws {
        let row = try row("fileio", title: "File I/O")
        #expect(row.title == "File I/O")
        #expect(mcpDisplayName(row) == "File I/O")
    }

    /// A server that declared no title falls back to its configured name, and
    /// gains no empty second identity.
    @Test func withoutATitleTheHeadingIsTheConfiguredName() throws {
        let row = try row("fileio")
        #expect(row.title == nil)
        #expect(mcpDisplayName(row) == "fileio")
    }

    /// The configured name is the identity used in configuration, namespacing
    /// and errors, so it survives on the row whatever the server calls itself. A
    /// server must not be able to make its own identity unfindable.
    @Test func theConfiguredNameSurvivesADeclaredTitle() throws {
        let row = try row("fileio", title: "System Utilities")
        #expect(row.name == "fileio")
    }

    // MARK: Sanitizing

    /// A title carrying newlines, tabs and control characters renders on one
    /// line. Whitespace runs collapse to a single space and the rest is dropped.
    @Test func aDeclaredTitleRendersOnOneLine() throws {
        let row = try row("srv", title: "  Multi\n\nline\tname\u{0007}  ")
        #expect(row.title == "Multiline name")
    }

    /// The same rule applies to a description.
    @Test func aDeclaredDescriptionRendersOnOneLine() throws {
        let row = try row("srv", description: "Reads\nand\twrites\u{0000} files")
        #expect(row.description == "Reads and writes files")
    }

    /// A description longer than the cap is clamped, so no server can push the
    /// rest of a row off screen.
    @Test func aLongDescriptionIsClamped() throws {
        let row = try row("srv", description: String(repeating: "a", count: 500))
        #expect(row.description?.count == mcpMaxDeclaredCharacters)
    }

    /// A value that is only whitespace and control characters is absent, not an
    /// empty string that would render as a blank line.
    @Test func anEmptyDeclaredValueIsAbsent() throws {
        let row = try row("srv", title: "   \n\t ", description: "\u{0001}")
        #expect(row.title == nil)
        #expect(row.description == nil)
    }

    // MARK: The website

    /// An `http(s)` website is offered as a link.
    @Test func anHttpWebsiteIsOffered() throws {
        #expect(try row("a", websiteURL: "https://example.com").websiteURL == "https://example.com")
        #expect(try row("b", websiteURL: "http://example.com").websiteURL == "http://example.com")
    }

    /// Every other scheme is refused, and a scheme-less value is refused rather
    /// than guessed at. A hostile server must not be able to put a
    /// `javascript:`, `file://` or `data:` URL behind a click in this panel.
    @Test func aNonHttpWebsiteIsRefused() throws {
        for hostile in [
            "javascript:alert(1)",
            "file:///etc/passwd",
            "data:text/html,<script>alert(1)</script>",
            "example.com",
            "//example.com",
            "ftp://example.com",
        ] {
            #expect(try row("srv", websiteURL: hostile).websiteURL == nil, "admitted \(hostile)")
        }
    }

    /// Scheme matching ignores case, the way the shared module does it.
    @Test func theWebsiteSchemeMatchIsCaseInsensitive() throws {
        #expect(try row("srv", websiteURL: "HTTPS://example.com").websiteURL == "HTTPS://example.com")
    }

    // MARK: Which populations can declare anything

    /// A client-run server has no `initialize` handshake behind it, so there is
    /// nothing it could have declared.
    @Test func aClientRunServerDeclaresNothing() throws {
        let rows = mcpServerRows(
            daemon: [],
            client: [
                McpClientServer(
                    name: "local", transport: "stdio", status: "running", toolCount: 1)
            ],
            builtins: [])
        let row = try #require(rows.first)
        #expect(row.title == nil)
        #expect(row.description == nil)
        #expect(row.websiteURL == nil)
        #expect(mcpDisplayName(row) == "local")
    }

    /// Nor does a built-in, which is compiled in rather than connected to.
    @Test func aBuiltinDeclaresNothing() throws {
        let rows = mcpServerRows(
            daemon: [],
            client: [],
            builtins: [McpBuiltinServer(name: "tasks", namespace: "tasks", toolCount: 3)])
        let row = try #require(rows.first)
        #expect(row.title == nil)
        #expect(row.description == nil)
        #expect(row.websiteURL == nil)
        #expect(mcpDisplayName(row) == "tasks")
    }

    // MARK: Decoding

    /// A daemon that sends none of the three fields decodes without error — the
    /// wire form omits them when absent.
    @Test func aViewWithoutDeclaredFieldsDecodes() throws {
        let view = try daemonView("srv")
        #expect(view.title == nil)
        #expect(view.description == nil)
        #expect(view.websiteURL == nil)
    }

    /// The Swift field names differ from the wire's `website_url`, so the
    /// mapping is asserted rather than assumed.
    @Test func theWireFieldNamesDecodeOntoTheSwiftProperties() throws {
        let view = try daemonView(
            "srv", title: "T", description: "D", websiteURL: "https://example.com")
        #expect(view.title == "T")
        #expect(view.description == "D")
        #expect(view.websiteURL == "https://example.com")
    }
}
