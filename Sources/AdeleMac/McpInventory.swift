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

    /// What the shared core exposes today, read through `core`.
    ///
    /// Built-ins arrive fully populated (adele-mac#12) — empty only when the core
    /// was built with no MCP servers linked in, which is the honest "none
    /// compiled in" rather than a missing answer. The external client-run
    /// population still has no FFI read path, so it stays empty; the panel then
    /// renders the daemon fleet plus the built-ins, and the runner filter still
    /// works (the Client bucket simply holds built-in rows only).
    static func live(_ core: AdeleCore) -> McpInventory {
        McpInventory(
            clientServers: { [] },
            builtinServers: { await core.mcpBuiltinServers() }
        )
    }

    /// Both populations empty — the panel then renders the daemon fleet alone.
    /// For previews and for callers with no core to read from.
    static let empty = McpInventory(clientServers: { [] }, builtinServers: { [] })
}
