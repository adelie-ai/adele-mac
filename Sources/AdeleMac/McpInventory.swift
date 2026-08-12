import AdeleCore
import Foundation

/// The two client-side MCP populations the settings panel merges with the
/// daemon fleet: the **client-run** servers this client hosts on the edge, and
/// the **built-in** servers compiled into the client and hosted in-process.
///
/// Why a seam rather than a direct call: adele-mac surfaces only what the
/// core/daemon expose (adele-mac#3), and the two populations became reachable at
/// different times. Both live behind the shared Rust core — the machine-local
/// `~/.config/adele/client-mcp.toml` the ffi engine loads, and (for built-ins)
/// the servers compiled into that cdylib and hosted in its own process. Keeping
/// the panel's source behind this one type means a population arriving on the
/// FFI changes only this file, and lets previews exercise rendering the linked
/// core cannot currently feed.
///
/// Deliberately NOT done here: re-reading or re-writing `client-mcp.toml` from
/// Swift. It is a machine-level file the Rust side owns — every other surface on
/// the box shares it, and its schema includes the per-surface
/// `disabled_builtins` set the built-in toggles write — so a second, independent
/// parser/writer would be a correctness hazard for all of them. The built-in
/// opt-out therefore goes through ``AdeleCore/setMcpBuiltinDisabled(name:disabled:)``,
/// which is the core writing its own file.
struct McpInventory: Sendable {
    /// External MCP servers this client runs on the edge.
    var clientServers: @Sendable () async -> [McpClientServer]
    /// MCP servers compiled into the client and hosted in-process.
    var builtinServers: @Sendable () async -> [McpBuiltinServer]
    /// Add an external client-run server, or edit the one of the same name.
    /// Answers with the refreshed client-run population.
    ///
    /// `enabled` sets both grains at once: the definition's own flag and this
    /// client's surface membership. The caller states it rather than leaning on
    /// the core's default, because an edit of a switched-off server turns it on,
    /// and the panel says so in the add form's note before the write.
    var upsertClientServer: @Sendable (_ name: String, _ command: String, _ args: [String],
        _ namespace: String?, _ enabled: Bool) async -> [McpClientServer]
    /// Delete an external client-run definition, for every client on the machine.
    var removeClientServer: @Sendable (_ name: String) async -> [McpClientServer]
    /// Turn an external client-run server on or off for this client alone.
    var setClientServerEnabled: @Sendable (_ name: String, _ enabled: Bool) async ->
        [McpClientServer]

    /// What the shared core exposes today, read through `core`.
    ///
    /// Both client-side populations arrive fully populated (adele-mac#3, #12) and
    /// are answerable with no connection: which servers are compiled in or
    /// configured is a property of how the core was built plus the machine-local
    /// `client-mcp.toml`, not of the daemon link. Either is empty only when
    /// nothing of that kind is linked/configured — the honest "none" rather than
    /// a missing answer. The panel merges both with the daemon fleet, and the
    /// runner filter buckets them under Client.
    static func live(_ core: AdeleCore) -> McpInventory {
        McpInventory(
            clientServers: { await core.mcpClientServers() },
            builtinServers: { await core.mcpBuiltinServers() },
            upsertClientServer: { name, command, args, namespace, enabled in
                await core.upsertMcpClientServer(
                    name: name, command: command, args: args, namespace: namespace,
                    enabled: enabled
                )
            },
            removeClientServer: { await core.removeMcpClientServer(name: $0) },
            setClientServerEnabled: { await core.setMcpClientServerEnabled(name: $0, enabled: $1) }
        )
    }

    /// Both populations empty, and every write a no-op that answers empty — the
    /// panel then renders the daemon fleet alone. For previews and for callers
    /// with no core to read from.
    static let empty = McpInventory(
        clientServers: { [] },
        builtinServers: { [] },
        upsertClientServer: { _, _, _, _, _ in [] },
        removeClientServer: { _ in [] },
        setClientServerEnabled: { _, _ in [] }
    )
}
