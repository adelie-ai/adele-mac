import AdeleCore
import SwiftUI

/// Standalone settings screen to list / add / remove / enable client-side MCP
/// servers. Issues management commands directly through `model.core` (like the
/// other per-feature settings surfaces) and reloads the list after each change.
/// Wire this in as a `SettingsView` tab, e.g.:
///   `McpSettingsView().tabItem { Label("MCP", systemImage: "puzzlepiece.extension") }`
struct McpSettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var servers: [McpServerView] = []
    @State private var loading = false
    @State private var error: String?

    // Add-server form.
    @State private var showingAdd = false
    @State private var newName = ""
    @State private var newCommand = ""
    @State private var newArgs = ""
    @State private var newNamespace = ""
    @State private var adding = false

    var body: some View {
        Form {
            if !model.connected {
                Text("Connect to manage MCP servers.")
                    .foregroundStyle(.secondary)
            } else {
                serverListSection
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
            if servers.isEmpty {
                Text(loading ? "Loading…" : "No MCP servers configured.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(servers) { server in
                    ServerRow(
                        server: server,
                        onToggle: { enabled in await setEnabled(server, enabled) },
                        onDelete: { await remove(server) }
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

    // MARK: Actions

    private func reload() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            servers = try await model.core.listMcpServers()
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

    private func setEnabled(_ server: McpServerView, _ enabled: Bool) async {
        do {
            try await model.core.setMcpServerEnabled(name: server.name, enabled: enabled)
            await reload()
        } catch {
            self.error = "Failed to update \(server.name): \(error)"
        }
    }

    private func remove(_ server: McpServerView) async {
        do {
            try await model.core.removeMcpServer(name: server.name)
            await reload()
        } catch {
            self.error = "Failed to remove \(server.name): \(error)"
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

/// One MCP server row: status dot, name, transport/target subtitle, tool count,
/// an enabled toggle and a delete action.
private struct ServerRow: View {
    let server: McpServerView
    let onToggle: (Bool) async -> Void
    let onDelete: () async -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .help(server.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(server.toolCount) tools")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Enabled", isOn: Binding(
                get: { server.enabled },
                set: { value in Task { await onToggle(value) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            Button(role: .destructive) {
                Task { await onDelete() }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove server")
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var text = "\(server.transport) — \(server.target)"
        if let detail = server.detail, !detail.isEmpty {
            text += " · \(detail)"
        }
        return text
    }

    /// running → green; error/auth issues → red/orange; disabled → gray;
    /// stopped/unknown → secondary.
    private var statusColor: Color {
        switch server.status {
        case "running": return .green
        case "error": return .red
        case "needs_auth", "auth_expired": return .orange
        case "disabled": return .gray
        default: return .secondary
        }
    }
}
