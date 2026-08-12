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
/// Who administers what: **daemon** rows get an enable toggle and a remove
/// button, issued through `model.core`'s daemon command surface. **Built-in**
/// rows get an enable toggle too, but it writes this client's per-surface
/// opt-out through the core (which owns the machine-wide `client-mcp.toml`);
/// they can never be removed, since they are compiled in. **External
/// client-run** rows are definitions in that same shared file: their toggle
/// writes this client's selection, and their remove deletes the definition for
/// every client on the machine. Every client-side read and write goes through
/// ``McpInventory``, so the core stays the only writer of that file.
///
/// The add form creates a server on either side. The location picker decides
/// which, and a client-run add works while disconnected, because the file it
/// writes is local.
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
    /// Set from the connection state every time the form opens, and on reset;
    /// this value only holds while the closed form describes no location.
    @State private var newLocation: McpAddLocation = .daemon
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
            // The client-side populations (built-in + external client-run) are
            // local to this machine and answerable with no connection, so the
            // list, its per-namespace counts and the add form all render while
            // disconnected. Only the daemon fleet, and adding a daemon-run
            // server, need a connection.
            serverListSection
            namespaceSection
            addSection
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        // Re-run when the connection flips: connecting loads the daemon fleet,
        // disconnecting clears it while the client-side rows stay put.
        .task(id: model.connected) { await reload() }
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
        } footer: {
            // With client-side rows present but disconnected, the absent daemon
            // rows are "not connected yet", not "none exist" — say so rather than
            // let the list imply the daemon runs nothing.
            if !model.connected {
                Text("Daemon-run servers appear once you connect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Honest about *why* the list is empty — ported to a pure helper so the
    /// "not connected ≠ no servers" decision is testable without a view host.
    private var emptyMessage: String {
        mcpEmptyServerListMessage(filter: filter, connected: model.connected, loading: loading)
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
                Picker("Runs on", selection: $newLocation) {
                    ForEach(McpAddLocation.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .help("Choose whether the daemon or this Mac runs the new server")
                TextField("Name", text: $newName)
                TextField("Command", text: $newCommand)
                TextField("Arguments (space or comma separated)", text: $newArgs)
                TextField("Namespace (optional)", text: $newNamespace)
                // A name that means more than a new server (an override, or an
                // edit of one already defined here) says so before the write.
                if let note = mcpAddNameNote(name: newName, location: newLocation, rows: rows) {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Cancel") { resetAddForm() }
                    Spacer()
                    Button("Add Server") { Task { await add() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canAdd || adding)
                }
            } else {
                Button {
                    // Read the connection now, not at the last reset: the form
                    // must open on a location that can be submitted, and this is
                    // the first open as often as not.
                    newLocation = mcpDefaultAddLocation(connected: model.connected)
                    showingAdd = true
                } label: {
                    Label("Add MCP Server", systemImage: "plus")
                }
            }
        } header: {
            Text("Add")
        } footer: {
            // Nothing while the form is closed: there is no picker on screen, so
            // there is no location to describe.
            if let footer = mcpAddFooter(
                location: newLocation, connected: model.connected, expanded: showingAdd
            ) {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var canAdd: Bool {
        !newName.trimmingCharacters(in: .whitespaces).isEmpty
            && !newCommand.trimmingCharacters(in: .whitespaces).isEmpty
            && mcpCanAdd(location: newLocation, connected: model.connected)
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
            guard let builtin = builtin(for: row) else { return mcpClientRowIsOn(row) }
            return mcpBuiltinToggleState(builtin).isOn
        }
    }

    // MARK: Actions

    private func reload() async {
        loading = true
        error = nil
        defer { loading = false }
        // The client-side populations are local, answerable offline, and cannot
        // fail; they load regardless of the connection so built-in and client-run
        // rows render while disconnected.
        let source = activeInventory
        clientServers = await source.clientServers()
        builtinServers = await source.builtinServers()
        // The daemon fetch genuinely needs a connection. While disconnected,
        // clear the fleet rather than attempt a fetch that would only surface a
        // "not connected" error over an otherwise usable panel.
        guard model.connected else {
            daemonServers = []
            return
        }
        do {
            daemonServers = try await model.core.listMcpServers()
        } catch {
            self.error = "Failed to load MCP servers: \(error)"
        }
    }

    /// Create the server on the side the form selected: the daemon's own fleet,
    /// or this Mac's `client-mcp.toml` through the core.
    private func add() async {
        adding = true
        defer { adding = false }
        let name = newName.trimmingCharacters(in: .whitespaces)
        let command = newCommand.trimmingCharacters(in: .whitespaces)
        let namespace = newNamespace.trimmingCharacters(in: .whitespaces)
        switch newLocation {
        case .daemon:
            do {
                try await model.core.addMcpServer(
                    name: name,
                    command: command,
                    args: parsedArgs,
                    namespace: namespace.isEmpty ? nil : namespace,
                    enabled: true
                )
                resetAddForm()
                await reload()
            } catch {
                self.error = "Failed to add server: \(error)"
            }
        case .client:
            // The core answers the write with the population it read back, so
            // the new row renders from disk rather than from an optimistic edit,
            // and the same answer says whether the write landed at all.
            error = nil
            let written = await activeInventory.upsertClientServer(
                name, command, parsedArgs, namespace.isEmpty ? nil : namespace, true
            )
            await applyClientWrite(written)
            // A refused write answers with the list still on disk, plus a toast
            // saying why. Keep the form open with what was typed in it, so the
            // person can correct the cause and try again.
            if let refused = mcpClientAddError(name: name, in: written) {
                error = refused
            } else {
                resetAddForm()
            }
        }
    }

    /// Take up a client-run write's answer: the population the core read back,
    /// and a fresh built-in population beside it.
    ///
    /// A client-run server overrides the built-in of the same name, and the core
    /// derives that override on every read - so an add, a toggle or a remove can
    /// change which built-in rows render as overridden, and what each one says.
    /// The per-namespace tool counts are computed from the same rows.
    private func applyClientWrite(_ servers: [McpClientServer]) async {
        clientServers = servers
        builtinServers = await activeInventory.builtinServers()
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
            if row.kind == .builtIn {
                builtinServers = await model.core.setMcpBuiltinDisabled(
                    name: row.name, disabled: !enabled
                )
            } else {
                // This client's own selection only: another client on this Mac
                // that lists the same server keeps running it.
                await applyClientWrite(
                    await activeInventory.setClientServerEnabled(row.name, enabled)
                )
            }
        }
    }

    /// The built-in a row was projected from, when it was one — the enable
    /// control's on/off and usability come from it, not from the row (which
    /// flattens the override and opt-out into one reason string).
    private func builtin(for row: McpServerRow) -> McpBuiltinServer? {
        guard row.kind == .builtIn else { return nil }
        return builtinServers.first { $0.name == row.name }
    }

    /// Remove a row's server: the daemon's own, or a client-run definition.
    ///
    /// A built-in is compiled into the core and offers no remove
    /// (`mcpRowActions`); the guard keeps that invariant local rather than
    /// trusting the caller.
    private func remove(_ row: McpServerRow) async {
        switch mcpBackend(for: row.runner) {
        case .daemon:
            do {
                try await model.core.removeMcpServer(name: row.name)
                await reload()
            } catch {
                self.error = "Failed to remove \(row.name): \(error)"
            }
        case .client:
            guard row.kind != .builtIn else { return }
            // Machine-wide: the definition goes for every client on this Mac.
            await applyClientWrite(await activeInventory.removeClientServer(row.name))
        }
    }

    private func resetAddForm() {
        showingAdd = false
        // Offer the location that can actually be used: while disconnected, only
        // this Mac can take a new server.
        newLocation = mcpDefaultAddLocation(connected: model.connected)
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
                    Text(mcpDisplayName(row))
                    // A server that declared a title keeps its configured name
                    // visible beside it: the name is the identity used in
                    // config, namespacing and errors, so a server must not be
                    // able to hide it behind a title it chose for itself.
                    if row.title != nil {
                        Text(row.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Chip(text: runnerLabel)
                    Chip(text: mcpKindLabel(row.kind))
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // What the server says it offers. Sanitized and clamped in
                // `mcpServerRows`, and rendered as plain text like every other
                // server-provided string on this row.
                if let description = row.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // Offered as a link, never opened on its own. Only an http(s)
                // URL reaches here.
                if let website = row.websiteURL, let url = URL(string: website) {
                    Link(website, destination: url)
                        .font(.caption)
                }
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
