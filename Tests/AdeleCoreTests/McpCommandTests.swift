import Testing
import Foundation
@testable import AdeleCore

/// Spec: the MCP-server management builders produce the exact `api::Command`
/// wire shape (externally tagged, snake_case), and `McpServerView` decodes the
/// documented subset of the daemon's descriptor while ignoring unknown fields.
@Suite struct McpCommandTests {
    private func object(_ json: String) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try #require(value as? [String: Any])
    }

    // MARK: add_mcp_server

    @Test func addMcpServerWithNamespace() throws {
        let json = AdeleCommand.addMcpServer(
            name: "fs",
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
            namespace: "files",
            enabled: true
        )
        let p = try #require((try object(json))["add_mcp_server"] as? [String: Any])
        #expect(p["name"] as? String == "fs")
        #expect(p["command"] as? String == "npx")
        #expect(p["args"] as? [String] == ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"])
        #expect(p["namespace"] as? String == "files")
        #expect(p["enabled"] as? Bool == true)
    }

    @Test func addMcpServerOmitsNamespaceWhenNil() throws {
        let json = AdeleCommand.addMcpServer(
            name: "git",
            command: "uvx",
            args: ["mcp-server-git"],
            namespace: nil,
            enabled: false
        )
        let p = try #require((try object(json))["add_mcp_server"] as? [String: Any])
        #expect(p["name"] as? String == "git")
        #expect(p["command"] as? String == "uvx")
        #expect(p["args"] as? [String] == ["mcp-server-git"])
        #expect(p["namespace"] == nil, "namespace must be omitted when nil (Option::is_none skips)")
        #expect(p["enabled"] as? Bool == false)
    }

    @Test func addMcpServerEnabledDefaultsTrue() throws {
        let json = AdeleCommand.addMcpServer(name: "n", command: "c", args: [])
        let p = try #require((try object(json))["add_mcp_server"] as? [String: Any])
        #expect(p["enabled"] as? Bool == true)
        #expect(p["args"] as? [String] == [])
        #expect(p["namespace"] == nil)
    }

    // MARK: remove_mcp_server

    @Test func removeMcpServerShape() throws {
        let json = AdeleCommand.removeMcpServer(name: "fs")
        let p = try #require((try object(json))["remove_mcp_server"] as? [String: Any])
        #expect(p["name"] as? String == "fs")
    }

    // MARK: set_mcp_server_enabled

    @Test func setMcpServerEnabledTrue() throws {
        let json = AdeleCommand.setMcpServerEnabled(name: "fs", enabled: true)
        let p = try #require((try object(json))["set_mcp_server_enabled"] as? [String: Any])
        #expect(p["name"] as? String == "fs")
        #expect(p["enabled"] as? Bool == true)
    }

    @Test func setMcpServerEnabledFalse() throws {
        let json = AdeleCommand.setMcpServerEnabled(name: "fs", enabled: false)
        let p = try #require((try object(json))["set_mcp_server_enabled"] as? [String: Any])
        #expect(p["enabled"] as? Bool == false)
    }

    // MARK: McpServerView decode (ignores unknown fields)

    @Test func mcpServerViewDecodesSubsetIgnoringUnknownFields() throws {
        let json = """
        {
          "name": "filesystem",
          "command": "npx",
          "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
          "namespace": "files",
          "enabled": true,
          "status": "running",
          "tool_count": 4,
          "transport": "stdio",
          "target": "npx -y @modelcontextprotocol/server-filesystem /tmp",
          "detail": null,
          "configure_label": "Sign in",
          "configure_command": ["/usr/bin/open", "https://example.test"],
          "auth_kind": "oauth",
          "oauth_authorized": false,
          "oauth_scopes": ["read", "write"],
          "oauth_client_id": "abc123"
        }
        """
        let view = try JSONDecoder().decode(McpServerView.self, from: Data(json.utf8))
        #expect(view.name == "filesystem")
        #expect(view.id == "filesystem")
        #expect(view.command == "npx")
        #expect(view.args == ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"])
        #expect(view.namespace == "files")
        #expect(view.enabled)
        #expect(view.status == "running")
        #expect(view.toolCount == 4)
        #expect(view.transport == "stdio")
        #expect(view.target == "npx -y @modelcontextprotocol/server-filesystem /tmp")
        #expect(view.detail == nil)
    }

    @Test func mcpServerViewDecodesMinimalWithOptionalsAbsent() throws {
        let json = """
        {
          "name": "git",
          "command": "uvx",
          "args": ["mcp-server-git"],
          "enabled": false,
          "status": "disabled",
          "tool_count": 0,
          "transport": "stdio",
          "target": "uvx mcp-server-git"
        }
        """
        let view = try JSONDecoder().decode(McpServerView.self, from: Data(json.utf8))
        #expect(view.name == "git")
        #expect(view.namespace == nil)
        #expect(view.detail == nil)
        #expect(view.enabled == false)
        #expect(view.status == "disabled")
        #expect(view.toolCount == 0)
    }

    @Test func mcpServersEnvelopeUnwrapsPayload() throws {
        let json = """
        {"type":"command_result","request_id":"r","ok":true,"result":{"mcp_servers":[{"name":"fs","command":"npx","args":[],"enabled":true,"status":"running","tool_count":2,"transport":"stdio","target":"npx"}]}}
        """
        struct Payload: Decodable { let mcp_servers: [McpServerView] }
        let env = try JSONDecoder().decode(CommandResultEnvelope<Payload>.self, from: Data(json.utf8))
        #expect(env.result?.mcp_servers.count == 1)
        #expect(env.result?.mcp_servers.first?.name == "fs")
        #expect(env.result?.mcp_servers.first?.toolCount == 2)
    }
}
