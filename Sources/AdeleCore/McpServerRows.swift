import Foundation

// The MCP-servers panel view-model: a Swift port of `client-ui-common`'s
// `mcp_servers` module (the same merge/sort/filter/label logic gtk and tui
// render), plus the small macOS-specific pure glue the panel needs.
//
// Why a port rather than a call into the core: the shared module is plain Rust
// with no C ABI — `libadele_client_core` exposes only the typed chat intents and
// the generic `adele_core_send_command` bridge, so none of `Runner`,
// `ServerKind`, `server_rows_with_builtins` or `runner_label` is reachable from
// Swift. Porting the ~100 lines of pure logic keeps the panel identical to the
// sibling clients today; the tests assert the shared behaviour literally
// (reason strings, sort order, chip text) so the two stay in step.
//
// Scope note (adele-mac#3): adele-mac surfaces only what the core/daemon expose.
// It hosts no in-process MCP servers of its own — the ffi cdylib it links
// depends on no `*-mcp` crate and starts its client MCP host with
// `McpHost::start` (never `start_with`), so there are no built-ins to enumerate
// and no client-server inventory on the FFI surface. The built-in and
// client-run populations are therefore modelled here in full (so the panel
// renders them correctly the moment a source exists) but are fed empty until
// the core exposes them. See `McpInventory` in the app target for that seam.

/// Where an MCP server actually runs. The panel groups and filters by this, and
/// it drives the [`mcpRunnerLabel`] chip.
public enum McpRunner: String, Sendable, Hashable, CaseIterable {
    /// Runs inside (or on behalf of) the daemon.
    case daemon
    /// Runs inside the client process (external client-run or in-process built-in).
    case client

    /// Stable tiebreak rank when two rows share a (case-insensitive) name:
    /// daemon-run servers sort ahead of client-run ones.
    fileprivate var sortRank: Int {
        switch self {
        case .daemon: return 0
        case .client: return 1
        }
    }
}

/// The runner filter backing the panel's dropdown. `all` is the default.
public enum McpRunnerFilter: String, Sendable, Hashable, CaseIterable {
    case all, daemon, client

    /// Menu text for the filter control.
    public var label: String {
        switch self {
        case .all: return "All"
        case .daemon: return "Daemon"
        case .client: return "Client"
        }
    }
}

/// How an MCP server is hosted — orthogonal to its ``McpRunner``. For external
/// servers the kind mirrors the transport, so the two agree.
public enum McpServerKind: String, Sendable, Hashable {
    /// External process speaking MCP over stdio.
    case stdio
    /// External endpoint speaking MCP over streamable HTTP.
    case http
    /// Compiled into the client and hosted in-process — no subprocess or socket.
    case builtIn

    /// Kind for an *external* server from its transport string: `"http"` → http,
    /// anything else → stdio (mirroring ``mcpTransportChip``'s stdio default).
    /// Built-in rows set their kind explicitly and never pass through here.
    fileprivate static func fromTransport(_ transport: String) -> McpServerKind {
        transport == "http" ? .http : .stdio
    }
}

/// One client-run (external) MCP server, as the host client resolves it from its
/// own registry. Mirrors the core's `ClientServerDto`.
public struct McpClientServer: Sendable, Hashable {
    public let name: String
    /// Transport: `"stdio"` or `"http"`.
    public let transport: String
    /// Display status string (e.g. `enabled` / `disabled`).
    public let status: String
    public let toolCount: UInt32
    /// Tool namespace; falls back to ``name`` when unset — the same key the
    /// client MCP host reports counts against.
    public let namespace: String?

    public init(
        name: String,
        transport: String,
        status: String,
        toolCount: UInt32,
        namespace: String? = nil
    ) {
        self.name = name
        self.transport = transport
        self.status = status
        self.toolCount = toolCount
        self.namespace = namespace
    }
}

/// One MCP server compiled into the client and hosted in-process. Mirrors the
/// core's `BuiltinServerDto`.
public struct McpBuiltinServer: Sendable, Hashable {
    /// Server name — also the key an external client-run server of the same name
    /// overrides.
    public let name: String
    /// The built-in's tool namespace (e.g. `"fileio"`).
    public let namespace: String
    public let toolCount: UInt32
    /// `Some(name)` when an external client-run server of the same name shadows
    /// this built-in (the external one wins and the built-in renders disabled).
    public let overriddenBy: String?
    /// `true` when the built-in was explicitly turned off for this surface in the
    /// client's config. Orthogonal to ``overriddenBy``: both can be set, and the
    /// disabled-in-config reason takes display precedence.
    public let disabledByConfig: Bool

    public init(
        name: String,
        namespace: String,
        toolCount: UInt32,
        overriddenBy: String? = nil,
        disabledByConfig: Bool = false
    ) {
        self.name = name
        self.namespace = namespace
        self.toolCount = toolCount
        self.overriddenBy = overriddenBy
        self.disabledByConfig = disabledByConfig
    }
}

/// One rendered row of the MCP-servers panel — the fields every client draws,
/// tagged with the ``McpRunner`` that produced it. Plain data.
public struct McpServerRow: Sendable, Hashable, Identifiable {
    public let name: String
    /// Which side runs this server.
    public let runner: McpRunner
    /// Transport: `"stdio"` / `"http"` (`"builtin"` for in-process rows, whose
    /// chip comes from ``kind``).
    public let transport: String
    /// Display status string, carried through from the source verbatim.
    public let status: String
    public let toolCount: UInt32
    /// Optional detail (e.g. a last connection error).
    public let detail: String?
    /// How the server is hosted (render via ``mcpKindLabel``).
    public let kind: McpServerKind
    /// `nil` when the row is active; otherwise the user-facing explanation for
    /// why it renders disabled.
    public let disabledReason: String?
    /// Tool namespace, resolved (never empty): the source's namespace, or the
    /// server name when it has none. Beyond the shared `ServerRow`, which drops
    /// it — the panel aggregates per-namespace tool counts from it.
    public let namespace: String

    /// Stable across the three populations: the same name can legitimately
    /// appear as a daemon row, an external client row, and a shadowed built-in.
    public var id: String { "\(runner.rawValue)/\(kind.rawValue)/\(name)" }
}

// MARK: - Labels

/// Human label for a row's runner.
///
/// - ``McpRunner/client`` → `"client"` (client tools always run locally, so
///   `isRemote`/`host` are ignored).
/// - ``McpRunner/daemon``, co-located link → `"daemon"`.
/// - ``McpRunner/daemon``, remote link with a known host → `"daemon · <host>"`.
public func mcpRunnerLabel(_ runner: McpRunner, isRemote: Bool, host: String?) -> String {
    switch runner {
    case .client:
        return "client"
    case .daemon:
        guard isRemote, let host, !host.isEmpty else { return "daemon" }
        return "daemon · \(host)"
    }
}

/// Honest transport chip text: `"stdio"` or `"http"`. Never emits the retired
/// "local"/"remote" conflation; anything that is not `"http"` reads as `"stdio"`
/// (the daemon only ever reports those two).
public func mcpTransportChip(_ transport: String) -> String {
    transport == "http" ? "http" : "stdio"
}

/// Human chip text for a row's ``McpServerKind``: `"stdio"` / `"http"` /
/// `"built-in"`. The unified successor to ``mcpTransportChip`` that also names
/// built-ins, so every row's chip can be rendered from `row.kind` alone.
public func mcpKindLabel(_ kind: McpServerKind) -> String {
    switch kind {
    case .stdio: return "stdio"
    case .http: return "http"
    case .builtIn: return "built-in"
    }
}

/// Human label for a coarse status string. Covers the daemon's six states plus
/// the two the client surface reports (`enabled`/`disabled`); an unrecognized
/// future state degrades to "Unknown" so an older client stays honest against a
/// newer daemon rather than crashing or inventing a state.
public func mcpStatusLabel(_ status: String) -> String {
    switch status {
    case "running": return "Running"
    case "enabled": return "Enabled"
    case "stopped": return "Stopped"
    case "disabled": return "Disabled"
    case "needs_auth": return "Sign in required"
    case "auth_expired": return "Sign in expired"
    case "error": return "Error"
    default: return "Unknown"
    }
}

// MARK: - Merge / filter

/// Merge daemon-run, external client-run, and built-in servers into one
/// panel-ordered list.
///
/// Daemon items are tagged ``McpRunner/daemon``; external client items and
/// built-ins are both ``McpRunner/client`` (a built-in is hosted in-process by
/// the client) and differ only in their ``McpServerKind``. A built-in whose
/// ``McpBuiltinServer/overriddenBy`` is set — or which is disabled in config —
/// renders disabled with the reason.
///
/// Sorted alphabetically by name (case-insensitive) with the runner as a stable
/// tiebreak (daemon before client). Built-ins are chained after the external
/// client rows, so on a name tie a shadowed built-in slots directly after its
/// active external override.
public func mcpServerRows(
    daemon: [McpServerView],
    client: [McpClientServer],
    builtins: [McpBuiltinServer] = []
) -> [McpServerRow] {
    let daemonRows = daemon.map { view in
        McpServerRow(
            name: view.name,
            runner: .daemon,
            transport: view.transport,
            status: view.status,
            toolCount: view.toolCount,
            detail: view.detail,
            kind: .fromTransport(view.transport),
            disabledReason: nil,
            namespace: resolvedNamespace(view.namespace, name: view.name)
        )
    }
    let clientRows = client.map { server in
        McpServerRow(
            name: server.name,
            runner: .client,
            transport: server.transport,
            status: server.status,
            toolCount: server.toolCount,
            detail: nil,
            kind: .fromTransport(server.transport),
            disabledReason: nil,
            namespace: resolvedNamespace(server.namespace, name: server.name)
        )
    }
    let builtinRows = builtins.map { builtin -> McpServerRow in
        // A built-in renders disabled when it was turned off in config OR
        // shadowed by a same-name external server. The config-disable reason
        // wins the display when both apply — it is the user's explicit choice.
        let reason: String?
        if builtin.disabledByConfig {
            reason = "disabled in this client's config"
        } else if let overrider = builtin.overriddenBy {
            reason = "overridden by the external \"\(overrider)\""
        } else {
            reason = nil
        }
        return McpServerRow(
            name: builtin.name,
            runner: .client,
            // Built-ins have no wire transport; the chip comes from `kind`.
            transport: "builtin",
            status: reason == nil ? "running" : "disabled",
            toolCount: builtin.toolCount,
            detail: nil,
            kind: .builtIn,
            disabledReason: reason,
            namespace: resolvedNamespace(builtin.namespace, name: builtin.name)
        )
    }

    // Case-insensitive name order with the runner as tiebreak. Swift's `sort` is
    // NOT stable, so the chain index is the final tiebreak — that is what keeps
    // an external override immediately ahead of the built-in it shadows.
    return (daemonRows + clientRows + builtinRows)
        .enumerated()
        .sorted { lhs, rhs in
            let l = lhs.element.name.lowercased(), r = rhs.element.name.lowercased()
            if l != r { return l < r }
            if lhs.element.runner != rhs.element.runner {
                return lhs.element.runner.sortRank < rhs.element.runner.sortRank
            }
            return lhs.offset < rhs.offset
        }
        .map(\.element)
}

/// Apply a ``McpRunnerFilter`` to already-built rows, preserving their order.
public func mcpFilterRows(_ rows: [McpServerRow], filter: McpRunnerFilter) -> [McpServerRow] {
    switch filter {
    case .all: return rows
    case .daemon: return rows.filter { $0.runner == .daemon }
    case .client: return rows.filter { $0.runner == .client }
    }
}

/// A namespace, and the tools live under it right now.
public struct McpNamespaceCount: Sendable, Hashable, Identifiable {
    public let namespace: String
    /// Tools exposed under this namespace by the servers currently serving it.
    public let toolCount: UInt32
    /// How many servers contribute to the namespace (a namespace can be served
    /// by more than one server — e.g. a daemon and a client row).
    public let serverCount: Int

    public var id: String { namespace }
}

/// Tool counts grouped by namespace, over the rows that are actually serving.
///
/// Only *live* rows contribute: a row with a disabled reason (a shadowed or
/// config-disabled built-in) is out, as is anything not `running`/`enabled` —
/// counting a stopped or errored server's last-known tools would overstate what
/// the assistant can actually call. Namespaces with no live server are omitted.
/// Sorted by namespace (case-insensitive).
public func mcpNamespaceToolCounts(_ rows: [McpServerRow]) -> [McpNamespaceCount] {
    var totals: [String: (tools: UInt32, servers: Int)] = [:]
    for row in rows where row.disabledReason == nil
        && (row.status == "running" || row.status == "enabled") {
        let current = totals[row.namespace] ?? (0, 0)
        totals[row.namespace] = (current.tools + row.toolCount, current.servers + 1)
    }
    return totals
        .map { McpNamespaceCount(namespace: $0.key, toolCount: $0.value.tools, serverCount: $0.value.servers) }
        .sorted { $0.namespace.lowercased() < $1.namespace.lowercased() }
}

// MARK: - macOS glue

/// Which backend administers a server of a given runner.
public enum McpBackend: Sendable, Hashable {
    /// Administer via the daemon's `SetMcpServerEnabled` / `RemoveMcpServer` /
    /// `AddMcpServer` command surface.
    case daemon
    /// Administer via the machine-local `client-mcp.toml` the shared core owns.
    case client
}

/// The runner fork: map a ``McpRunner`` to the ``McpBackend`` that administers it.
public func mcpBackend(for runner: McpRunner) -> McpBackend {
    switch runner {
    case .daemon: return .daemon
    case .client: return .client
    }
}

/// Whether the client's link to the daemon is remote, and the host to name in
/// the runner chip when it is.
public struct McpDaemonLink: Sendable, Hashable {
    public let isRemote: Bool
    public let host: String?
}

/// Derive the runner chip's `(isRemote, host)` from the WebSocket address this
/// client connects to.
///
/// adele-mac speaks only WebSocket, so the link is always remote (the daemon may
/// be on another host) — matching gtk, which treats every `Ws` connection that
/// way. An address that yields no host degrades to a plain "daemon" label rather
/// than an error.
public func mcpDaemonLink(wsURL: String) -> McpDaemonLink {
    let host = URLComponents(string: wsURL)?.host.flatMap { $0.isEmpty ? nil : $0 }
    return McpDaemonLink(isRemote: true, host: host)
}

/// What a row lets the user do, and why not when it doesn't.
public struct McpRowActions: Sendable, Hashable {
    public let canToggle: Bool
    public let canRemove: Bool
    /// Explanation shown when the controls are unavailable (`nil` when they are).
    public let help: String?
}

/// The controls a row offers.
///
/// adele-mac administers only the daemon fleet: client-run and built-in servers
/// are owned by the shared core (the machine-local `client-mcp.toml` and the
/// core's in-process host), which exposes no write path over the FFI. Their rows
/// are therefore read-only and say why, rather than offering a control that
/// silently does nothing. A disabled built-in explains itself with the row's own
/// reason (shadowed, or turned off in config).
public func mcpRowActions(for row: McpServerRow) -> McpRowActions {
    switch mcpBackend(for: row.runner) {
    case .daemon:
        return McpRowActions(canToggle: true, canRemove: true, help: nil)
    case .client:
        let help = row.disabledReason
            ?? (row.kind == .builtIn
                ? "Built into the client core and hosted in-process."
                : "Run by this client from the machine's client-mcp.toml.")
        return McpRowActions(canToggle: false, canRemove: false, help: help)
    }
}

/// The source namespace, or the server name when it has none/blank — the key the
/// MCP host reports tool counts against.
private func resolvedNamespace(_ namespace: String?, name: String) -> String {
    guard let namespace, !namespace.isEmpty else { return name }
    return namespace
}
