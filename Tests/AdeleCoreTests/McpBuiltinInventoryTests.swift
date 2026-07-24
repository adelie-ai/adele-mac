import Foundation
import Testing

@testable import AdeleCore

/// The built-in MCP inventory, end to end against the **live linked core**
/// (adele-mac#12).
///
/// These are the only tests in the suite that instantiate a real `AdeleCore`.
/// They still need no daemon and no UI: which servers are compiled in is a
/// property of how `libadele_client_core` was built, and the per-surface opt-out
/// is a local file — so the whole read/write path is answerable offline.
///
/// **What "the linked core" means.** `just test-with-mcp` links a core carrying
/// the built-in servers; a plain `./scripts/test.sh` links the default core,
/// which carries none (adele-kde shares that build). Both are legitimate, so the
/// assertions below are written against whichever is linked, and
/// `ADELE_EXPECT_BUILTINS` (a comma-separated list) pins the exact set when the
/// caller knows it — e.g.
/// `ADELE_EXPECT_BUILTINS=fileio,terminal,tasks,web just test-with-mcp`.
///
/// **Serialized** because each test points the core at its own throwaway
/// `XDG_CONFIG_HOME`, which is process-global state.
@Suite(.serialized) struct McpBuiltinInventoryTests {
    // MARK: Harness

    /// A throwaway `XDG_CONFIG_HOME` the core resolves `client-mcp.toml` under.
    ///
    /// Without this a test would read — and the write-path tests would *edit* —
    /// the developer's real `~/.config/adele/client-mcp.toml`.
    private struct ConfigHome {
        let configPath: URL

        /// Replace the client MCP config (the core re-reads it on every request,
        /// so a live core sees the new contents without being recreated).
        func write(_ toml: String) throws {
            try toml.write(to: configPath, atomically: true, encoding: .utf8)
        }

        var toml: String {
            (try? String(contentsOf: configPath, encoding: .utf8)) ?? ""
        }
    }

    /// Run `body` with the core's config lookup redirected into a fresh temp
    /// directory, restoring the previous `XDG_CONFIG_HOME` afterwards.
    ///
    /// Main-actor isolated so `body` stays in the tests' own isolation domain —
    /// it drives a main-actor `AdeleCore`, and hopping domains would make the
    /// closure a `sending` value.
    @MainActor private func withConfigHome(
        seed: String? = nil,
        _ body: (ConfigHome) async throws -> Void
    ) async throws {
        let previous = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("adele-mac-mcp-\(UUID().uuidString)")
        let home = ConfigHome(configPath: root.appendingPathComponent("adele/client-mcp.toml"))
        try FileManager.default.createDirectory(
            at: home.configPath.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if let seed { try home.write(seed) }
        setenv("XDG_CONFIG_HOME", root.path, 1)
        defer {
            if let previous {
                setenv("XDG_CONFIG_HOME", previous, 1)
            } else {
                unsetenv("XDG_CONFIG_HOME")
            }
            try? FileManager.default.removeItem(at: root)
        }
        try await body(home)
    }

    /// The `disabled_builtins` list written under `[surfaces.<surface>]`, or
    /// `nil` when the file has no such section.
    ///
    /// Scanned rather than string-matched because the surfaces are serialized
    /// from a hash map: their order is not stable, so an assertion has to find
    /// its section rather than assume a layout.
    private func disabledBuiltins(surface: String, in toml: String) -> [String]? {
        var section: String?
        var found: [String]?
        for rawLine in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                section = line
                if line == "[surfaces.\(surface)]" { found = [] }
                continue
            }
            guard section == "[surfaces.\(surface)]", line.hasPrefix("disabled_builtins") else {
                continue
            }
            found = line
                .drop(while: { $0 != "[" }).dropFirst().prefix(while: { $0 != "]" })
                .split(separator: ",")
                .map {
                    $0.trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
                .filter { !$0.isEmpty }
        }
        return found
    }

    /// A core that has declared the Mac's surface, exactly as `AppModel.init` does.
    @MainActor private func macCore() -> AdeleCore {
        let core = AdeleCore()
        core.setMcpSurface(AdeleCore.macMcpSurface)
        return core
    }

    /// The exact built-in set the caller pinned via `ADELE_EXPECT_BUILTINS`, if any.
    private var expectedBuiltins: [String]? {
        ProcessInfo.processInfo.environment["ADELE_EXPECT_BUILTINS"]
            .map { $0.split(separator: ",").map(String.init).sorted() }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: Acceptance

    /// `builtin_rows_render_from_live_core` — every built-in the linked core
    /// reports arrives with the fields the panel draws and projects into a
    /// well-formed built-in row: client runner, built-in kind, a resolved
    /// namespace, and a live tool count.
    @MainActor @Test func builtinRowsRenderFromLiveCore() async throws {
        try await withConfigHome { _ in
            let core = macCore()
            let builtins = await core.mcpBuiltinServers()
            let rows = mcpServerRows(daemon: [], client: [], builtins: builtins)

            #expect(rows.count == builtins.count, "every built-in becomes exactly one row")
            for row in rows {
                #expect(row.kind == .builtIn)
                #expect(row.runner == .client, "a built-in is hosted in this client's process")
                #expect(row.transport == "builtin")
                #expect(!row.namespace.isEmpty, "the namespace is what tool counts key on")
                #expect(
                    row.disabledReason == nil,
                    "nothing is configured or opted out here, so no row is disabled"
                )
                #expect(row.status == "running")
            }
            // The runner filter is the panel's only re-projection: built-ins are
            // Client rows and must never leak into the Daemon bucket.
            #expect(mcpFilterRows(rows, filter: .client).count == rows.count)
            #expect(mcpFilterRows(rows, filter: .daemon).isEmpty)

            if let expected = expectedBuiltins {
                #expect(
                    builtins.map(\.name).sorted() == expected,
                    "the linked core must host exactly the pinned built-in set"
                )
                for builtin in builtins {
                    #expect(builtin.toolCount > 0, "\(builtin.name) must advertise tools")
                    #expect(!builtin.namespace.isEmpty)
                }
                // Tool counts are what the "Tools by namespace" section aggregates;
                // built-in namespaces are unique, so one bucket each.
                #expect(mcpNamespaceToolCounts(rows).count == builtins.count)
            }
        }
    }

    /// `default_core_shows_no_builtin_rows` — a core built with no `mcp-*`
    /// feature (adele-kde's build) reports nothing, and the panel then renders no
    /// built-in row at all rather than implying servers it does not host.
    @MainActor @Test func defaultCoreShowsNoBuiltinRows() async throws {
        try await withConfigHome { _ in
            let core = macCore()
            let builtins = await core.mcpBuiltinServers()

            if builtins.isEmpty {
                let rows = mcpServerRows(daemon: [], client: [], builtins: builtins)
                #expect(rows.isEmpty, "a default-featured core contributes no rows")
                #expect(mcpFilterRows(rows, filter: .client).isEmpty)
            } else {
                // A core WITH built-ins is linked, so the default-core case can't
                // be observed live here; pin the same guarantee against an empty
                // inventory so the assertion still has teeth in this build.
                let rows = mcpServerRows(daemon: [], client: [], builtins: [])
                #expect(!rows.contains { $0.kind == .builtIn })
            }
        }
    }

    /// `overridden_builtin_renders_as_shadowed` — an external `client-mcp.toml`
    /// server of the same name wins, the core reports the built-in as shadowed by
    /// it, and the row renders disabled directly after its override.
    @MainActor @Test func overriddenBuiltinRendersAsShadowed() async throws {
        // The rendering + sort rule, pinned without depending on which servers
        // this particular core links.
        let external = McpClientServer(
            name: "fileio", transport: "stdio", status: "enabled", toolCount: 2
        )
        let shadowed = McpBuiltinServer(
            name: "fileio", namespace: "fileio", toolCount: 7, overriddenBy: "fileio"
        )
        let rows = mcpServerRows(daemon: [], client: [external], builtins: [shadowed])
        #expect(rows.map(\.kind) == [.stdio, .builtIn], "the shadowed built-in sorts after it")
        #expect(rows[1].disabledReason == #"overridden by the external "fileio""#)
        #expect(rows[1].status == "disabled")

        // And live: the core itself must do the shadow bookkeeping.
        try await withConfigHome { home in
            let core = macCore()
            guard let target = await core.mcpBuiltinServers().first else {
                return  // no built-ins linked; the rule above is the whole spec here
            }

            try home.write(
                """
                [[servers]]
                name = "\(target.name)"
                command = "/usr/bin/true"

                [surfaces.mac]
                enabled = ["\(target.name)"]
                """
            )
            let refreshed = await core.mcpBuiltinServers()
            let builtin = try #require(refreshed.first { $0.name == target.name })
            #expect(builtin.overriddenBy == target.name, "the core names the shadowing server")
            #expect(!builtin.disabledByConfig, "an override is not an opt-out")

            let projected = mcpServerRows(daemon: [], client: [], builtins: [builtin])
            #expect(projected[0].disabledReason != nil, "a shadowed built-in renders disabled")
        }
    }

    /// `disabling_a_builtin_writes_the_mac_surface` — the opt-out lands in
    /// `[surfaces.mac]`, never in another client's section, and the rest of the
    /// shared file survives.
    ///
    /// Meaningful on every core build: the write path is config-only, so it does
    /// not depend on which servers are compiled in.
    @MainActor @Test func disablingABuiltinWritesTheMacSurface() async throws {
        try await withConfigHome(
            seed: """
                [[servers]]
                name = "notes"
                command = "/usr/bin/notes-mcp"

                [surfaces.kde]
                enabled = ["notes"]
                disabled_builtins = ["terminal"]
                """
        ) { home in
            let core = macCore()

            _ = await core.setMcpBuiltinDisabled(name: "fileio", disabled: true)

            let written = home.toml
            #expect(
                disabledBuiltins(surface: "mac", in: written) == ["fileio"],
                "the opt-out belongs to the mac surface: \(written)"
            )
            #expect(
                disabledBuiltins(surface: "kde", in: written) == ["terminal"],
                "another client's section must be untouched: \(written)"
            )
            #expect(written.contains("notes"), "the shared server definitions must survive")

            // And back off again — the toggle must work in both directions.
            _ = await core.setMcpBuiltinDisabled(name: "fileio", disabled: false)
            #expect(disabledBuiltins(surface: "mac", in: home.toml) == [])
        }
    }

    /// `client_run_servers_render_from_live_core` — an external server the mac
    /// surface enables arrives over the FFI (adele-mac#3) with the fields the
    /// panel draws and projects into a well-formed client-run row: client runner,
    /// a transport-derived kind, a resolved namespace, and — offline — an enabled
    /// status with no live tool count yet.
    @MainActor @Test func clientRunServersRenderFromLiveCore() async throws {
        try await withConfigHome(
            seed: """
                [[servers]]
                name = "browser"
                command = "/usr/bin/browser-mcp"
                namespace = "web"

                [[servers]]
                name = "remote"
                namespace = "rem"
                [servers.http]
                url = "https://example.test/mcp"

                [surfaces.mac]
                enabled = ["browser", "remote"]
                """
        ) { _ in
            let core = macCore()
            let servers = await core.mcpClientServers()

            let browser = try #require(servers.first { $0.name == "browser" })
            #expect(browser.transport == "stdio")
            #expect(browser.status == "enabled", "offline: configured but no host running yet")
            #expect(browser.toolCount == 0)
            #expect(browser.namespace == "web")

            // An HTTP endpoint reports the http transport honestly, never a guess.
            let remote = try #require(servers.first { $0.name == "remote" })
            #expect(remote.transport == "http")

            let rows = mcpServerRows(daemon: [], client: servers, builtins: [])
            let row = try #require(rows.first { $0.name == "browser" })
            #expect(row.runner == .client, "a client-run server is hosted by this client")
            #expect(row.kind == .stdio)
            #expect(row.namespace == "web", "the namespace is what tool counts key on")
            #expect(mcpFilterRows(rows, filter: .client).count == rows.count)
            #expect(mcpFilterRows(rows, filter: .daemon).isEmpty)
        }
    }

    /// `client_side_rows_render_while_disconnected` — the two client-side reads
    /// the panel's inventory delegates to answer with no connection (adele-mac#3,
    /// #12), so the merged rows carry the client-run (and built-in) servers even
    /// with no daemon fleet present. Gap 2: a disconnected panel is not an empty
    /// one — the connection gates only the daemon population.
    @MainActor @Test func clientSideRowsRenderWhileDisconnected() async throws {
        try await withConfigHome(
            seed: """
                [[servers]]
                name = "browser"
                command = "/usr/bin/browser-mcp"
                namespace = "web"

                [surfaces.mac]
                enabled = ["browser"]
                """
        ) { _ in
            let core = macCore()  // connect() is never called

            // Both client-side seams answer offline.
            let client = await core.mcpClientServers()
            let builtins = await core.mcpBuiltinServers()

            // With no daemon fleet (disconnected), the merged rows are exactly the
            // client-side populations — never empty when either is configured.
            let rows = mcpServerRows(daemon: [], client: client, builtins: builtins)
            #expect(
                rows.contains { $0.name == "browser" && $0.runner == .client },
                "the configured client-run server renders with no connection"
            )
            #expect(
                rows.allSatisfy { $0.runner == .client },
                "no daemon rows while disconnected, yet the client side still renders"
            )
            #expect(
                rows.count == client.count + builtins.count,
                "every client-side server becomes a row; nothing is dropped offline"
            )
        }
    }

    /// The opt-out must also be what the core then *reports*, so the panel shows
    /// the pending state instead of looking unchanged until the next connect.
    @MainActor @Test func aDisabledBuiltinComesBackFlagged() async throws {
        try await withConfigHome { _ in
            let core = macCore()
            guard let target = await core.mcpBuiltinServers().first else {
                return  // no built-ins linked in this core build
            }

            let refreshed = await core.setMcpBuiltinDisabled(name: target.name, disabled: true)
            let builtin = try #require(refreshed.first { $0.name == target.name })
            #expect(builtin.disabledByConfig, "the toggle is reflected before the next connect")

            let projected = mcpServerRows(daemon: [], client: [], builtins: [builtin])
            #expect(projected[0].disabledReason == "disabled in this client's config")
            #expect(projected[0].status == "disabled")
        }
    }
}
