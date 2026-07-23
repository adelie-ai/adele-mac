import Testing
import Foundation
@testable import AdeleCore

/// Spec for the MCP-servers panel view-model — the Swift port of
/// `client-ui-common::mcp_servers` (`Runner` / `ServerKind` / `ServerRow`,
/// `runner_label` / `kind_label` / `transport_chip`, `server_rows_with_builtins`,
/// `filter_rows`) plus the macOS-specific pure glue the panel needs
/// (`mcpDaemonLink`, `mcpBackend(for:)`, `mcpRowActions(for:)`,
/// `mcpNamespaceToolCounts`).
///
/// Every assertion that mirrors a Rust behaviour is deliberately literal
/// (reason strings, sort order, chip text) so the two panels stay in step: a
/// user moving between the gtk and macOS clients must see the same words.
@Suite struct McpServerRowsTests {
    // MARK: Fixtures

    /// A daemon `McpServerView` with only the fields the view-model reads set.
    /// Decoded from JSON because the type has no memberwise init (it mirrors the
    /// wire form) — which also keeps these fixtures honest about the wire shape.
    private func daemonView(
        _ name: String,
        transport: String = "stdio",
        status: String = "running",
        tools: UInt32 = 0,
        namespace: String? = nil,
        detail: String? = nil,
        enabled: Bool = true
    ) throws -> McpServerView {
        var fields: [String: Any] = [
            "name": name,
            "command": "cmd",
            "args": [String](),
            "enabled": enabled,
            "status": status,
            "tool_count": tools,
            "transport": transport,
            "target": "cmd",
        ]
        if let namespace { fields["namespace"] = namespace }
        if let detail { fields["detail"] = detail }
        let data = try JSONSerialization.data(withJSONObject: fields)
        return try JSONDecoder().decode(McpServerView.self, from: data)
    }

    private func clientServer(
        _ name: String,
        transport: String = "stdio",
        status: String = "enabled",
        tools: UInt32 = 0,
        namespace: String? = nil
    ) -> McpClientServer {
        McpClientServer(
            name: name, transport: transport, status: status, toolCount: tools, namespace: namespace
        )
    }

    private func builtin(
        _ name: String,
        tools: UInt32 = 0,
        overriddenBy: String? = nil,
        disabledByConfig: Bool = false
    ) -> McpBuiltinServer {
        McpBuiltinServer(
            name: name,
            namespace: name,
            toolCount: tools,
            overriddenBy: overriddenBy,
            disabledByConfig: disabledByConfig
        )
    }

    // MARK: runner label (core `runner_label`)

    @Test func runnerLabelClientIgnoresRemoteAndHost() {
        #expect(mcpRunnerLabel(.client, isRemote: false, host: nil) == "client")
        #expect(mcpRunnerLabel(.client, isRemote: true, host: "lab-host") == "client")
    }

    @Test func runnerLabelDaemonAddsHostOnlyWhenRemote() {
        #expect(mcpRunnerLabel(.daemon, isRemote: false, host: nil) == "daemon")
        #expect(mcpRunnerLabel(.daemon, isRemote: false, host: "lab-host") == "daemon")
        #expect(mcpRunnerLabel(.daemon, isRemote: true, host: nil) == "daemon")
        #expect(mcpRunnerLabel(.daemon, isRemote: true, host: "lab-host") == "daemon · lab-host")
    }

    // MARK: chips (core `transport_chip` / `kind_label`)

    @Test func transportChipIsOnlyStdioOrHttp() {
        #expect(mcpTransportChip("stdio") == "stdio")
        #expect(mcpTransportChip("http") == "http")
        // Honest: never the retired local/remote conflation, and anything
        // unrecognized degrades to stdio (the daemon only sends those two).
        #expect(mcpTransportChip("builtin") == "stdio")
        #expect(mcpTransportChip("whatever") == "stdio")
    }

    @Test func kindLabelNamesEachKindAndAgreesWithTransportChip() {
        #expect(mcpKindLabel(.stdio) == "stdio")
        #expect(mcpKindLabel(.http) == "http")
        #expect(mcpKindLabel(.builtIn) == "built-in")
        #expect(mcpKindLabel(.stdio) == mcpTransportChip("stdio"))
        #expect(mcpKindLabel(.http) == mcpTransportChip("http"))
    }

    // MARK: merge (core `server_rows_with_builtins`)

    @Test func rowsTagRunnerAndDeriveKindPerSource() throws {
        let daemon = [try daemonView("alpha", status: "error", detail: "boom")]
        let client = [clientServer("beta", transport: "http", tools: 1)]

        let rows = mcpServerRows(daemon: daemon, client: client)
        #expect(rows.count == 2)

        let alpha = try #require(rows.first { $0.name == "alpha" })
        #expect(alpha.runner == .daemon)
        #expect(alpha.transport == "stdio")
        #expect(alpha.status == "error")
        #expect(alpha.detail == "boom")
        #expect(alpha.kind == .stdio)
        #expect(alpha.disabledReason == nil)

        let beta = try #require(rows.first { $0.name == "beta" })
        #expect(beta.runner == .client)
        #expect(beta.kind == .http)
        #expect(beta.detail == nil, "client rows carry no daemon-side detail")
        #expect(beta.disabledReason == nil)
    }

    @Test func rowsSortCaseInsensitivelyWithDaemonBeforeClientOnTies() throws {
        let daemon = [
            try daemonView("Zeta"),
            try daemonView("alpha"),
            try daemonView("github", transport: "http"),
        ]
        let client = [clientServer("Beta", transport: "http"), clientServer("github")]

        let rows = mcpServerRows(daemon: daemon, client: client)
        #expect(rows.map(\.name) == ["alpha", "Beta", "github", "github", "Zeta"])
        #expect(
            rows.filter { $0.name.lowercased() == "github" }.map(\.runner) == [.daemon, .client]
        )
    }

    @Test func rowsHandleEmptySources() throws {
        #expect(mcpServerRows(daemon: [], client: []).isEmpty)

        let onlyDaemon = mcpServerRows(daemon: [try daemonView("alpha")], client: [])
        #expect(onlyDaemon.map(\.runner) == [.daemon])

        let onlyClient = mcpServerRows(daemon: [], client: [clientServer("beta")])
        #expect(onlyClient.map(\.runner) == [.client])

        let onlyBuiltin = mcpServerRows(daemon: [], client: [], builtins: [builtin("notes", tools: 2)])
        #expect(onlyBuiltin.map(\.runner) == [.client])
        #expect(onlyBuiltin.map(\.kind) == [.builtIn])
    }

    // MARK: built-ins (scope items 2 + 3)

    @Test func activeBuiltinRowIsClientRunnerBuiltInKindAndRunning() {
        let rows = mcpServerRows(daemon: [], client: [], builtins: [builtin("fileio", tools: 7)])
        let row = rows[0]
        #expect(row.name == "fileio")
        #expect(row.runner == .client)
        #expect(row.kind == .builtIn)
        #expect(row.toolCount == 7)
        #expect(row.status == "running")
        #expect(row.transport == "builtin", "built-ins have no wire transport")
        #expect(row.disabledReason == nil)
    }

    @Test func overriddenBuiltinRowIsDisabledWithReason() {
        let rows = mcpServerRows(
            daemon: [], client: [], builtins: [builtin("fileio", tools: 7, overriddenBy: "fileio-client")]
        )
        let row = rows[0]
        #expect(row.status == "disabled")
        #expect(row.disabledReason == "overridden by the external \"fileio-client\"")
    }

    @Test func configDisabledBuiltinRowIsDisabledWithReason() {
        let rows = mcpServerRows(
            daemon: [], client: [], builtins: [builtin("web", tools: 2, disabledByConfig: true)]
        )
        let row = rows[0]
        #expect(row.status == "disabled")
        #expect(row.disabledReason == "disabled in this client's config")
    }

    @Test func configDisableReasonWinsOverOverrideReason() {
        let rows = mcpServerRows(
            daemon: [],
            client: [],
            builtins: [builtin("fileio", tools: 7, overriddenBy: "fileio-client", disabledByConfig: true)]
        )
        #expect(rows[0].status == "disabled")
        #expect(
            rows[0].disabledReason == "disabled in this client's config",
            "the user's explicit config choice must win the displayed reason"
        )
    }

    @Test func shadowedBuiltinSortsDirectlyAfterItsExternalOverride() throws {
        let daemon = [try daemonView("Zeta"), try daemonView("git", transport: "http", tools: 2)]
        let client = [clientServer("fileio", tools: 4)]
        let builtins = [builtin("fileio", tools: 3, overriddenBy: "fileio"), builtin("alpha", tools: 2)]

        let rows = mcpServerRows(daemon: daemon, client: client, builtins: builtins)
        #expect(rows.map(\.name) == ["alpha", "fileio", "fileio", "git", "Zeta"])

        #expect(rows[0].kind == .builtIn)
        #expect(rows[0].disabledReason == nil)

        // External override first (active), then the built-in it shadows.
        #expect(rows[1].runner == .client)
        #expect(rows[1].kind == .stdio)
        #expect(rows[1].disabledReason == nil)
        #expect(rows[2].kind == .builtIn)
        #expect(rows[2].disabledReason == "overridden by the external \"fileio\"")

        #expect(rows[3].kind == .http)
        #expect(rows[4].kind == .stdio)
    }

    @Test func rowIdentitySeparatesSameNameRowsAcrossRunnerAndKind() throws {
        let rows = mcpServerRows(
            daemon: [try daemonView("fileio")],
            client: [clientServer("fileio")],
            builtins: [builtin("fileio", overriddenBy: "fileio")]
        )
        #expect(rows.count == 3)
        #expect(Set(rows.map(\.id)).count == 3, "rows must be uniquely identifiable for ForEach")
    }

    // MARK: filter (core `filter_rows`, scope item 1)

    @Test func filterRowsAllDaemonClientWithBuiltinsRidingClient() throws {
        let rows = mcpServerRows(
            daemon: [try daemonView("alpha")],
            client: [clientServer("beta", transport: "http")],
            builtins: [builtin("notes", tools: 2)]
        )
        #expect(McpRunnerFilter.allCases == [.all, .daemon, .client])
        #expect(mcpFilterRows(rows, filter: .all).count == 3)

        let daemonOnly = mcpFilterRows(rows, filter: .daemon)
        #expect(daemonOnly.count == 1)
        #expect(daemonOnly.allSatisfy { $0.runner == .daemon })

        let clientOnly = mcpFilterRows(rows, filter: .client)
        #expect(clientOnly.count == 2, "a built-in is client-run and rides the Client filter")
        #expect(clientOnly.allSatisfy { $0.runner == .client })
    }

    @Test func filterPreservesRowOrder() throws {
        let rows = mcpServerRows(
            daemon: [try daemonView("delta"), try daemonView("alpha")],
            client: [clientServer("charlie"), clientServer("bravo")]
        )
        #expect(mcpFilterRows(rows, filter: .all).map(\.name) == ["alpha", "bravo", "charlie", "delta"])
        #expect(mcpFilterRows(rows, filter: .daemon).map(\.name) == ["alpha", "delta"])
        #expect(mcpFilterRows(rows, filter: .client).map(\.name) == ["bravo", "charlie"])
    }

    // MARK: status label

    @Test func statusLabelCoversEveryKnownStateAndDegradesHonestly() {
        #expect(mcpStatusLabel("running") == "Running")
        #expect(mcpStatusLabel("enabled") == "Enabled")
        #expect(mcpStatusLabel("stopped") == "Stopped")
        #expect(mcpStatusLabel("disabled") == "Disabled")
        #expect(mcpStatusLabel("needs_auth") == "Sign in required")
        #expect(mcpStatusLabel("auth_expired") == "Sign in expired")
        #expect(mcpStatusLabel("error") == "Error")
        // A newer daemon's unknown state must render, not crash.
        #expect(mcpStatusLabel("quantum") == "Unknown")
        #expect(mcpStatusLabel("") == "Unknown")
    }

    // MARK: daemon link (drives the runner chip's host suffix)

    @Test func daemonLinkFromWebSocketURLIsRemoteWithHost() {
        let link = mcpDaemonLink(wsURL: "ws://lab-host:8080/ws")
        #expect(link.isRemote)
        #expect(link.host == "lab-host")

        let secure = mcpDaemonLink(wsURL: "wss://adele.example.test/ws")
        #expect(secure.isRemote)
        #expect(secure.host == "adele.example.test")
    }

    @Test func daemonLinkWithoutParsableHostStaysPlainDaemon() {
        // A WS link is always remote (the daemon may be on another host), but an
        // unparsable address yields no host suffix rather than an error.
        for address in ["", "not a url", "ws://"] {
            let link = mcpDaemonLink(wsURL: address)
            #expect(link.isRemote)
            #expect(link.host == nil, "\(address) must not produce a host suffix")
            #expect(mcpRunnerLabel(.daemon, isRemote: link.isRemote, host: link.host) == "daemon")
        }
    }

    // MARK: the runner fork (which backend administers a row)

    @Test func backendForksOnRunner() {
        #expect(mcpBackend(for: .daemon) == .daemon)
        #expect(mcpBackend(for: .client) == .client)
    }

    @Test func daemonRowsAreEditableAndClientAndBuiltinRowsAreNot() throws {
        let rows = mcpServerRows(
            daemon: [try daemonView("alpha")],
            client: [clientServer("beta")],
            builtins: [builtin("web", disabledByConfig: true)]
        )
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0) })

        let daemonActions = mcpRowActions(for: try #require(byName["alpha"]))
        #expect(daemonActions.canToggle)
        #expect(daemonActions.canRemove)
        #expect(daemonActions.help == nil)

        // adele-mac administers only the daemon fleet: client-run and built-in
        // servers are owned by the shared core, so their rows are read-only and
        // must say why rather than offering a control that does nothing.
        let clientActions = mcpRowActions(for: try #require(byName["beta"]))
        #expect(!clientActions.canToggle)
        #expect(!clientActions.canRemove)
        #expect(clientActions.help != nil)

        let builtinActions = mcpRowActions(for: try #require(byName["web"]))
        #expect(!builtinActions.canToggle)
        #expect(!builtinActions.canRemove)
        #expect(
            builtinActions.help == "disabled in this client's config",
            "a disabled built-in explains itself with the row's reason"
        )
    }

    // MARK: per-namespace tool counts (scope item 5)

    @Test func namespaceToolCountsAggregateLiveRowsAndFallBackToName() throws {
        let daemon = [
            try daemonView("github-issues", status: "running", tools: 4, namespace: "github"),
            try daemonView("github-prs", status: "running", tools: 3, namespace: "github"),
            try daemonView("time", status: "running", tools: 1),
        ]
        let counts = mcpNamespaceToolCounts(mcpServerRows(daemon: daemon, client: []))

        #expect(counts.map(\.namespace) == ["github", "time"], "sorted by namespace")
        #expect(counts[0].toolCount == 7)
        #expect(counts[0].serverCount == 2)
        #expect(counts[1].toolCount == 1, "a server with no namespace counts under its own name")
        #expect(counts[1].serverCount == 1)
    }

    @Test func namespaceToolCountsExcludeStoppedAndDisabledRows() throws {
        let daemon = [
            try daemonView("live", status: "running", tools: 2, namespace: "ns"),
            try daemonView("down", status: "stopped", tools: 9, namespace: "ns"),
            try daemonView("off", status: "disabled", tools: 5, namespace: "gone", enabled: false),
            try daemonView("broken", status: "error", tools: 4, namespace: "gone"),
        ]
        let counts = mcpNamespaceToolCounts(mcpServerRows(daemon: daemon, client: []))
        #expect(counts.map(\.namespace) == ["ns"], "only namespaces with a live server appear")
        #expect(counts[0].toolCount == 2)
        #expect(counts[0].serverCount == 1)
    }

    @Test func namespaceToolCountsSpanRunnersAndSkipShadowedBuiltins() throws {
        // A built-in and a same-named external override share one namespace: only
        // the active row contributes, so the count is not double-charged.
        let rows = mcpServerRows(
            daemon: [try daemonView("fileio-remote", status: "running", tools: 1, namespace: "fileio")],
            client: [clientServer("fileio", status: "enabled", tools: 4)],
            builtins: [builtin("fileio", tools: 3, overriddenBy: "fileio")]
        )
        let counts = mcpNamespaceToolCounts(rows)
        #expect(counts.map(\.namespace) == ["fileio"])
        #expect(counts[0].toolCount == 5, "1 daemon + 4 external client; the shadowed built-in is out")
        #expect(counts[0].serverCount == 2)
    }

    @Test func namespaceToolCountsAreEmptyWithoutRows() {
        #expect(mcpNamespaceToolCounts([]).isEmpty)
    }

    // MARK: decode tolerance — a daemon that omits the newer optional fields

    @Test func rowsBuildFromADaemonViewMissingNamespaceAndDetail() throws {
        let json = """
        {"name":"git","command":"uvx","args":["mcp-server-git"],"enabled":true,
         "status":"running","tool_count":2,"transport":"stdio","target":"uvx mcp-server-git"}
        """
        let view = try JSONDecoder().decode(McpServerView.self, from: Data(json.utf8))
        let row = mcpServerRows(daemon: [view], client: [])[0]
        #expect(row.namespace == "git", "an absent namespace falls back to the server name")
        #expect(row.detail == nil)
        #expect(row.kind == .stdio)
        #expect(row.disabledReason == nil)
    }
}
