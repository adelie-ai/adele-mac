import AdeleCore
import Foundation

/// The two client-side MCP populations the settings panel merges with the
/// daemon fleet: the **client-run** servers this client hosts on the edge, and
/// the **built-in** servers compiled into the client and hosted in-process.
///
/// Why a seam rather than a direct call: adele-mac surfaces only what the
/// core/daemon expose (adele-mac#3). Both populations live behind the shared
/// Rust core — the machine-local `~/.config/adele/client-mcp.toml` the ffi
/// engine loads, and (for built-ins) an in-process host the ffi cdylib does not
/// currently build. Neither is reachable over the C ABI, which carries only the
/// typed chat intents and the generic `send_command` bridge. So the panel is
/// wired to render both populations correctly and asks for them through this
/// seam; ``core`` answers empty until the core grows the corresponding FFI
/// calls, at which point this file is the only one that changes.
///
/// Deliberately NOT done here: re-reading and re-writing `client-mcp.toml` from
/// Swift. It is a machine-level file the Rust side owns (and whose schema
/// includes the per-surface `disabled_builtins` set built-in toggles write), and
/// a second, independent parser/writer for it would be a correctness hazard for
/// every other surface sharing the file.
struct McpInventory: Sendable {
    /// External MCP servers this client runs on the edge.
    var clientServers: @Sendable () async -> [McpClientServer]
    /// MCP servers compiled into the client and hosted in-process.
    var builtinServers: @Sendable () async -> [McpBuiltinServer]

    /// What the shared core exposes today: neither population. The panel then
    /// renders the daemon fleet alone, and the runner filter still works (the
    /// Client bucket is simply empty).
    static let core = McpInventory(clientServers: { [] }, builtinServers: { [] })
}
