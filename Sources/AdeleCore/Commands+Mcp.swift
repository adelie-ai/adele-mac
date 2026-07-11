import Foundation

/// Pure builders for the client-side MCP-server management commands
/// (`api::Command` variants `AddMcpServer` / `RemoveMcpServer` /
/// `SetMcpServerEnabled`). Externally tagged, snake_case — see `Commands.swift`
/// for the shared `encode` helper and wire conventions. `listMcpServers` (the
/// unit variant) already lives in `Commands.swift`; reuse it.
extension AdeleCommand {
    /// `{"add_mcp_server":{"name":…,"command":…,"args":[…],"namespace":<string|omitted>,"enabled":<bool>}}`.
    /// `namespace` is omitted when nil (mirrors `#[serde(skip_serializing_if =
    /// "Option::is_none")]`); `enabled` defaults true (mirrors the daemon's
    /// `default_true`).
    public static func addMcpServer(
        name: String,
        command: String,
        args: [String],
        namespace: String? = nil,
        enabled: Bool = true
    ) -> String {
        struct Payload: Encodable {
            let name: String
            let command: String
            let args: [String]
            let namespace: String?
            let enabled: Bool
        }
        struct Cmd: Encodable { let add_mcp_server: Payload }
        return encode(Cmd(add_mcp_server: Payload(
            name: name,
            command: command,
            args: args,
            namespace: namespace,
            enabled: enabled
        )))
    }

    /// `{"remove_mcp_server":{"name":…}}`.
    public static func removeMcpServer(name: String) -> String {
        struct Cmd: Encodable {
            struct P: Encodable { let name: String }
            let remove_mcp_server: P
        }
        return encode(Cmd(remove_mcp_server: .init(name: name)))
    }

    /// `{"set_mcp_server_enabled":{"name":…,"enabled":<bool>}}`.
    public static func setMcpServerEnabled(name: String, enabled: Bool) -> String {
        struct Cmd: Encodable {
            struct P: Encodable { let name: String; let enabled: Bool }
            let set_mcp_server_enabled: P
        }
        return encode(Cmd(set_mcp_server_enabled: .init(name: name, enabled: enabled)))
    }
}
