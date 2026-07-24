import AdeleCore
import SwiftUI

/// Settings screen for the Model Context Protocol servers the user can
/// administer, merging the populations a client can see into one list: the
/// **daemon** fleet (`ListMcpServers`), this **client**'s edge-run servers, and
/// the client's compiled-in **built-in** servers hosted in-process.
///
/// Each row carries a runner chip ("daemon"/"daemon · host"/"client"), a kind
/// chip ("stdio"/"http"/"built-in"), an honest status, and its tool count; a
/// filter re-projects the same data (All / Daemon / Client) without a re-fetch.
/// The merge/sort/filter/label logic is the unit-tested view-model in
/// `AdeleCore` (`mcpServerRows` / `mcpFilterRows` / `mcpRunnerLabel` /
/// `mcpKindLabel`); this file is the thin SwiftUI shell over it.
///
/// Who administers what: **daemon** rows get an enable toggle, a remove button
/// and the add form, all issued through `model.core`'s daemon command surface.
/// **Built-in** rows get an enable toggle too, but it writes this client's
/// per-surface opt-out through the core (which owns the machine-wide
/// `client-mcp.toml`); they can never be removed, since they are compiled in.
/// **External client-run** rows are definitions in that same shared file, which
/// this panel does not administer, so they render read-only with the reason
/// (`mcpRowActions`). Both client-side populations arrive through
/// ``McpInventory``.
///
/// Wire this in as a `SettingsView` tab, e.g.:
///   `McpSettingsView().tabItem { Label("MCP", systemImage: "puzzlepiece.extension") }`
struct McpSettingsView: View {
    @Environment(AppModel.self) private var model

    /// Where the client-run + built-in populations come from. `nil` reads them
    /// from the app's core; previews inject a fixed inventory to exercise
    /// rendering the linked core may not feed (its built-ins are chosen at build
    /// time via `just build-with-mcp`).
    var inventory: McpInventory?

    /// The inventory in force: the injected one, else the live core.
    private var activeInventory: McpInventory { inventory ?? .live(model.core) }

    @State private var daemonServers: [McpServerView] = []
    @State private var clientServers: [McpClientServer] = []
    @State private var builtinServers: [McpBuiltinServer] = []
    @State private var filter: McpRunnerFilter = .all
    @State private var loading = false
    @State private var error: String?

    // Add-server form.
    @State private var showingAdd = false
    @State private var newName = ""
    @State private var newCommand = ""
    @State private var newArgs = ""
    @State private var newNamespace = ""
    @State private var adding = false

    /// The merged, panel-ordered rows across all three populations.
    private var rows: [McpServerRow] {
        mcpServerRows(daemon: daemonServers, client: clientServers, builtins: builtinServers)
    }

    /// The rows the active runner filter shows.
    private var visibleRows: [McpServerRow] {
        mcpFilterRows(rows, filter: filter)
    }

    /// The daemon link behind the runner chip's host suffix. adele-mac speaks
    /// only WebSocket, so the daemon may be on another host.
    private var daemonLink: McpDaemonLink {
        mcpDaemonLink(wsURL: model.serverAddress)
    }

    var body: some View {
        Form {
            if !model.connected {
                Text("Connect to manage MCP servers.")
                    .foregroundStyle(.secondary)
            } else {
                serverListSection
                namespaceSection
                addSection
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .task { await reload() }
    }

    // MARK: Server list

    @ViewBuilder private var serverListSection: some View {
        Section {
            Picker("Runner", selection: $filter) {
                ForEach(McpRunnerFilter.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Show servers run by the daemon, by this client, or both")

            if visibleRows.isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visibleRows) { row in
                    McpServerRowView(
                        row: row,
                        builtin: builtin(for: row),
                        target: target(for: row),
                        enabled: isEnabled(row),
                        runnerLabel: mcpRunnerLabel(
                            row.runner, isRemote: daemonLink.isRemote, host: daemonLink.host
                        ),
                        onToggle: { enabled in await setEnabled(row, enabled) },
                        onDelete: { await remove(row) }
                    )
                }
            }
        } header: {
            HStack {
                Text("Servers")
                Spacer()
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
                .disabled(loading)
            }
        }
    }

    /// Honest about *why* the list is empty: loading, filtered out, or genuinely
    /// nothing configured.
    private var emptyMessage: String {
        if loading { return "Loading…" }
        switch filter {
        case .all: return "No MCP servers configured."
        case .daemon: return "The daemon runs no MCP servers."
        case .client: return "This client runs no MCP servers."
        }
    }

    // MARK: Tools by namespace

    @ViewBuilder private var namespaceSection: some View {
        let counts = mcpNamespaceToolCounts(rows)
        if !counts.isEmpty {
            Section {
                ForEach(counts) { count in
                    HStack {
                        Text(count.namespace)
                        Spacer()
                        Text(toolsPhrase(count.toolCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if count.serverCount > 1 {
                            Text("· \(count.serverCount) servers")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Tools by namespace")
            } footer: {
                Text("Counts only servers that are running right now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Add form

    @ViewBuilder private var addSection: some View {
        Section {
            if showingAdd {
                TextField("Name", text: $newName)
                TextField("Command", text: $newCommand)
                TextField("Arguments (space or comma separated)", text: $newArgs)
                TextField("Namespace (optional)", text: $newNamespace)
                HStack {
                    Button("Cancel") { resetAddForm() }
                    Spacer()
                    Button("Add Server") { Task { await add() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canAdd || adding)
                }
            } else {
                Button {
                    showingAdd = true
                } label: {
                    Label("Add MCP Server", systemImage: "plus")
                }
            }
        } header: {
            Text("Add")
        } footer: {
            Text("Added servers are run by the daemon.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var canAdd: Bool {
        !newName.trimmingCharacters(in: .whitespaces).isEmpty
            && !newCommand.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Split the args field on whitespace and commas, dropping empties.
    private var parsedArgs: [String] {
        newArgs
            .split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" || $0 == "\n" })
            .map(String.init)
    }

    // MARK: Row lookups

    /// The daemon-only connection target (command or url); client and built-in
    /// rows have none to show.
    private func target(for row: McpServerRow) -> String? {
        guard row.runner == .daemon else { return nil }
        return daemonServers.first { $0.name == row.name }?.target
    }

    /// The toggle's state. Daemon rows carry an explicit `enabled` flag; a
    /// built-in reads on iff this surface has not opted out of it (an override
    /// dims the row but leaves the switch on, because the built-in *is* still
    /// enabled in config); anything else reports state only through its status.
    private func isEnabled(_ row: McpServerRow) -> Bool {
        switch row.runner {
        case .daemon:
            return daemonServers.first { $0.name == row.name }?.enabled ?? false
        case .client:
            guard let builtin = builtin(for: row) else { return row.disabledReason == nil }
            return mcpBuiltinToggleState(builtin).isOn
        }
    }

    // MARK: Actions

    private func reload() async {
        loading = true
        error = nil
        defer { loading = false }
        // The client-side populations are local and cannot fail; only the daemon
        // fetch can, and a failure there must not blank the rest of the panel.
        let source = activeInventory
        clientServers = await source.clientServers()
        builtinServers = await source.builtinServers()
        do {
            daemonServers = try await model.core.listMcpServers()
        } catch {
            self.error = "Failed to load MCP servers: \(error)"
        }
    }

    private func add() async {
        adding = true
        defer { adding = false }
        let namespace = newNamespace.trimmingCharacters(in: .whitespaces)
        do {
            try await model.core.addMcpServer(
                name: newName.trimmingCharacters(in: .whitespaces),
                command: newCommand.trimmingCharacters(in: .whitespaces),
                args: parsedArgs,
                namespace: namespace.isEmpty ? nil : namespace,
                enabled: true
            )
            resetAddForm()
            await reload()
        } catch {
            self.error = "Failed to add server: \(error)"
        }
    }

    /// The runner fork, both directions of it.
    ///
    /// A daemon row's toggle goes to the daemon's `SetMcpServerEnabled`. A
    /// built-in's writes this client's per-surface opt-out through the core,
    /// which owns the shared `client-mcp.toml` — the core answers with the
    /// refreshed inventory, so the row reflects the change immediately even
    /// though the running MCP host only picks it up on the next connect. An
    /// external client-run row offers no toggle at all (`mcpRowActions`); the
    /// guards here keep that invariant local rather than trusting the caller.
    private func setEnabled(_ row: McpServerRow, _ enabled: Bool) async {
        switch mcpBackend(for: row.runner) {
        case .daemon:
            do {
                try await model.core.setMcpServerEnabled(name: row.name, enabled: enabled)
                await reload()
            } catch {
                self.error = "Failed to update \(row.name): \(error)"
            }
        case .client:
            guard row.kind == .builtIn else { return }
            builtinServers = await model.core.setMcpBuiltinDisabled(
                name: row.name, disabled: !enabled
            )
        }
    }

    /// The built-in a row was projected from, when it was one — the enable
    /// control's on/off and usability come from it, not from the row (which
    /// flattens the override and opt-out into one reason string).
    private func builtin(for row: McpServerRow) -> McpBuiltinServer? {
        guard row.kind == .builtIn else { return nil }
        return builtinServers.first { $0.name == row.name }
    }

    private func remove(_ row: McpServerRow) async {
        guard mcpBackend(for: row.runner) == .daemon else { return }
        do {
            try await model.core.removeMcpServer(name: row.name)
            await reload()
        } catch {
            self.error = "Failed to remove \(row.name): \(error)"
        }
    }

    private func resetAddForm() {
        showingAdd = false
        newName = ""
        newCommand = ""
        newArgs = ""
        newNamespace = ""
    }
}

/// `"1 tool"` / `"n tools"`.
private func toolsPhrase(_ count: UInt32) -> String {
    "\(count) tool\(count == 1 ? "" : "s")"
}

/// One MCP server row: status dot, name with runner + kind chips, a status
/// subtitle carrying the tool count and (for daemon rows) the target, the last
/// connection error, an enable toggle for daemon and built-in rows, and a remove
/// action for daemon rows only. Rows that cannot serve render dimmed, and a row
/// whose control is unavailable explains why.
private struct McpServerRowView: View {
    let row: McpServerRow
    /// The built-in this row was projected from, when it is one — the enable
    /// control's usability turns on the override/opt-out split the row flattens.
    let builtin: McpBuiltinServer?
    /// The daemon-only connection target, when there is one.
    let target: String?
    let enabled: Bool
    let runnerLabel: String
    let onToggle: (Bool) async -> Void
    let onDelete: () async -> Void

    private var actions: McpRowActions { mcpRowActions(for: row, builtin: builtin) }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .help(mcpStatusLabel(row.status))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.name)
                    Chip(text: runnerLabel)
                    Chip(text: mcpKindLabel(row.kind))
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let detail = row.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let reason = row.disabledReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .italic()
                }
            }
            Spacer()
            Toggle("Enabled", isOn: Binding(
                get: { enabled },
                set: { value in Task { await onToggle(value) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(!actions.canToggle)
            .help(actions.help ?? "Enable or disable this server")
            if actions.canRemove {
                Button(role: .destructive) {
                    Task { await onDelete() }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove server")
            }
        }
        .padding(.vertical, 2)
        // A row that cannot serve (shadowed / disabled built-in) reads dimmed,
        // matching the sibling clients.
        .opacity(row.disabledReason == nil ? 1 : 0.55)
    }

    /// Status label, plus the tool count when the server is actually serving,
    /// plus the daemon's connection target when it has one.
    private var subtitle: String {
        var text = mcpStatusLabel(row.status)
        if (row.status == "running" || row.status == "enabled") && row.toolCount > 0 {
            text += " · \(toolsPhrase(row.toolCount))"
        }
        if let target, !target.isEmpty {
            text += " · \(target)"
        }
        return text
    }

    /// running/enabled → green; error → red; auth issues → orange; disabled →
    /// gray; stopped/unknown → secondary.
    private var statusColor: Color {
        switch row.status {
        case "running", "enabled": return .green
        case "error": return .red
        case "needs_auth", "auth_expired": return .orange
        case "disabled": return .gray
        default: return .secondary
        }
    }
}

/// A small rounded chip for the runner / kind labels.
private struct Chip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
    }
}
