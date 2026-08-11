import Foundation

/// Wire form of a configured MCP server — the per-server descriptor the config
/// surface renders (mirrors api-model `McpServerView`). We decode only the
/// subset the macOS settings screen surfaces; `JSONDecoder` ignores the many
/// extra optional oauth/configure fields the daemon may also send.
public struct McpServerView: Decodable, Identifiable, Hashable, Sendable {
    public let name: String
    /// Display name the server declared for itself in `serverInfo.title`
    /// (SEP-973). ``name`` stays the programmatic identity used in config,
    /// namespacing and errors, so a renderer must keep it visible.
    public let title: String?
    /// What the server says it offers (`serverInfo.description`).
    public let description: String?
    /// The server's home page (`serverInfo.websiteUrl`). **Untrusted** — a
    /// renderer must check the scheme before offering it as a link; the panel
    /// model does that in ``mcpServerRows(daemon:client:builtins:)``.
    public let websiteURL: String?
    public let command: String
    public let args: [String]
    public let namespace: String?
    public let enabled: Bool
    /// Coarse state: `disabled` | `running` | `stopped` | `needs_auth` |
    /// `auth_expired` | `error`.
    public let status: String
    public let toolCount: UInt32
    /// Transport: `"stdio"` or `"http"`.
    public let transport: String
    /// Human-facing connection target: the command (stdio) or url (http).
    public let target: String
    /// Last connection error, when the server failed to connect.
    public let detail: String?

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, title, description, command, args, namespace, enabled, status, transport, target,
            detail
        case toolCount = "tool_count"
        case websiteURL = "website_url"
    }
}

// MARK: - Typed MCP-server management commands over the generic bridge

extension AdeleCore {
    private struct McpServersPayload: Decodable { let mcp_servers: [McpServerView] }

    /// List the configured client-side MCP servers (`CommandResult::McpServers`).
    @MainActor
    public func listMcpServers() async throws -> [McpServerView] {
        let data = try await sendCommand(AdeleCommand.listMcpServers)
        return try JSONDecoder().decode(CommandResultEnvelope<McpServersPayload>.self, from: data)
            .result?.mcp_servers ?? []
    }

    /// Add (or replace) an MCP server. Replies `Ack`, or throws on error.
    @MainActor
    public func addMcpServer(
        name: String,
        command: String,
        args: [String],
        namespace: String? = nil,
        enabled: Bool = true
    ) async throws {
        _ = try await sendCommand(AdeleCommand.addMcpServer(
            name: name, command: command, args: args, namespace: namespace, enabled: enabled
        ))
    }

    /// Remove an MCP server by name. Replies `Ack`, or throws on error.
    @MainActor
    public func removeMcpServer(name: String) async throws {
        _ = try await sendCommand(AdeleCommand.removeMcpServer(name: name))
    }

    /// Enable or disable an MCP server by name. Replies `Ack`, or throws on error.
    @MainActor
    public func setMcpServerEnabled(name: String, enabled: Bool) async throws {
        _ = try await sendCommand(AdeleCommand.setMcpServerEnabled(name: name, enabled: enabled))
    }
}
