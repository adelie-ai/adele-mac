import AdeleCore
import SwiftUI

/// Editable Connections settings tab: list configured LLM connections and
/// create / edit / delete them over the management bridge (`model.core`).
///
/// This is the read/write counterpart to the read-only `ConnectionsSettings`
/// in `SettingsView.swift`; wire it in as its own settings tab. It keeps its
/// own load/error state (rather than `AppModel`'s) so it can be dropped in
/// without touching the shared model.
struct ConnectionsEditorView: View {
    @Environment(AppModel.self) private var model

    @State private var connections: [ConnectionView] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var editor: ConnectionEditorTarget?

    var body: some View {
        Form {
            if !model.connected {
                Text("Connect to manage connections.")
                    .foregroundStyle(.secondary)
            } else {
                Section {
                    if connections.isEmpty {
                        Text(loading ? "Loading…" : "No connections configured.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(connections) { connection in
                            Button { editor = .existing(connection) } label: {
                                ConnectionEditorRow(connection: connection)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Edit") { editor = .existing(connection) }
                                Button("Delete", role: .destructive) {
                                    Task { await delete(id: connection.id, force: false) }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Connections")
                } footer: {
                    Text("The API key itself is provided as the named environment variable (`api_key_env`) on the daemon — this screen only sets which variable to read.")
                }

                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.red)
                }

                HStack {
                    Button { editor = .new } label: {
                        Label("Add Connection", systemImage: "plus")
                    }
                    Spacer()
                    Button("Refresh") { Task { await load() } }
                        .disabled(loading)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editor, onDismiss: { Task { await load() } }) { target in
            ConnectionEditorSheet(target: target)
                .environment(model)
        }
        .task { await load() }
    }

    private func load() async {
        guard model.connected else { return }
        loading = true
        defer { loading = false }
        do {
            connections = try await model.core.listConnections()
            errorText = nil
        } catch {
            errorText = "Could not load connections: \(error)"
        }
    }

    private func delete(id: String, force: Bool) async {
        do {
            try await model.core.deleteConnection(id: id, force: force)
            await load()
        } catch {
            errorText = "Delete failed: \(error)"
        }
    }
}

/// Distinguishes an "add new" editor session from editing an existing row.
private enum ConnectionEditorTarget: Identifiable {
    case new
    case existing(ConnectionView)

    var id: String {
        switch self {
        case .new: return "new"
        case .existing(let c): return c.id
        }
    }
}

/// One connection row: availability dot, id/label, connector type, and a
/// credential-status key icon — mirrors the read-only `ConnectionsSettings`.
private struct ConnectionEditorRow: View {
    let connection: ConnectionView

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(connection.availability.isOk ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.displayLabel)
                Text(connection.availability.isOk
                    ? connection.connectorType
                    : "\(connection.connectorType) — \(connection.availability.reason ?? "unavailable")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: connection.hasCredentials ? "key.fill" : "key.slash")
                .foregroundStyle(connection.hasCredentials ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                .help(connection.hasCredentials ? "Credentials present" : "No credentials")
        }
        .padding(.vertical, 2)
    }
}

/// Add/edit sheet. On save it issues `create_connection` (new) or
/// `update_connection` (existing) via `model.core`; the parent reloads on
/// dismiss.
private struct ConnectionEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: ConnectionEditorTarget

    @State private var id = ""
    @State private var connectorType = "anthropic"
    @State private var baseURL = ""
    @State private var apiKeyEnv = ""
    @State private var awsProfile = ""
    @State private var region = ""
    @State private var keepWarm = false
    @State private var connectTimeout = ""
    @State private var streamTimeout = ""
    @State private var maxTokens = ""
    // Raw credentials entered directly (stored in the daemon's secret store, not
    // in daemon.toml). Blank on edit = keep the existing secret untouched.
    @State private var apiKey = ""
    @State private var awsAccessKey = ""
    @State private var awsSecretKey = ""
    @State private var awsSessionToken = ""
    @State private var saving = false
    @State private var errorText: String?

    private var isNew: Bool {
        if case .new = target { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "New Connection" : "Edit Connection")
                .font(.headline)
                .padding([.top, .horizontal], 16)

            Form {
                Section {
                    TextField("Connection id (slug)", text: $id)
                        .disabled(!isNew)
                        .help(isNew ? "Lowercase slug, e.g. \"work\" or \"local-ollama\"." : "The id cannot be changed.")
                    Picker("Connector type", selection: $connectorType) {
                        ForEach(ConnectionConfigInput.allConnectorTypes, id: \.self) { type in
                            Text(label(for: type)).tag(type)
                        }
                    }
                }

                Section {
                    TextField(baseURLPrompt, text: $baseURL)
                    if connectorType == "anthropic" || connectorType == "openai" {
                        TextField("API key env var (api_key_env)", text: $apiKeyEnv)
                        SecureField(secretPrompt, text: $apiKey)
                    }
                    if connectorType == "bedrock" {
                        TextField("AWS profile (aws_profile)", text: $awsProfile)
                        TextField("Region (e.g. us-east-1)", text: $region)
                        SecureField("AWS Access Key ID (optional)", text: $awsAccessKey)
                        SecureField("AWS Secret Access Key", text: $awsSecretKey)
                        SecureField("AWS Session Token (optional)", text: $awsSessionToken)
                    }
                    if connectorType == "ollama" {
                        Toggle("Keep model warm (keep_warm)", isOn: $keepWarm)
                    }
                } footer: {
                    Text(credentialFooter).font(.caption)
                }

                Section("Advanced (optional)") {
                    TextField("Connect timeout (secs)", text: $connectTimeout)
                    TextField("Stream timeout (secs)", text: $streamTimeout)
                    TextField("Max context tokens", text: $maxTokens)
                }

                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(isNew ? "Create" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || id.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 480, height: 520)
        .onAppear(perform: prefill)
    }

    private var baseURLPrompt: String {
        connectorType == "ollama" ? "Base URL (e.g. http://localhost:11434)" : "Base URL (optional override)"
    }

    private var secretPrompt: String {
        isNew ? "API key (optional — stored securely on the daemon)"
              : "API key (re-enter to keep — saving an edit clears the stored key)"
    }

    private var credentialFooter: String {
        // Saving an edit rewrites the connection config, which clears its stored
        // secret coordinate — so on edit the credential must be re-entered to keep it.
        let editNote = isNew ? "" : " Saving this edit clears the stored credential — re-enter it to keep it."
        switch connectorType {
        case "anthropic", "openai":
            return "Provide the key via an environment variable on the daemon (api_key_env) or by entering it here — stored in the daemon's secret store, never in daemon.toml." + editNote
        case "bedrock":
            return "Enter AWS keys to store them securely on the daemon (no ~/.aws or env vars needed), or leave blank to use ambient credentials (profile / role / IRSA)." + editNote
        default:
            return "Ollama runs locally and needs no credentials."
        }
    }

    /// The raw credential to store, assembled from the entered fields, or nil to
    /// leave the connection's stored secret untouched. Bedrock joins the AWS
    /// parts as `ACCESS:SECRET[:SESSION]` (the connector's static-credential form).
    private var credentialValue: String? {
        switch connectorType {
        case "anthropic", "openai":
            return trimmedOrNil(apiKey)
        case "bedrock":
            guard let access = trimmedOrNil(awsAccessKey), let secret = trimmedOrNil(awsSecretKey) else {
                return nil
            }
            if let session = trimmedOrNil(awsSessionToken) {
                return "\(access):\(secret):\(session)"
            }
            return "\(access):\(secret)"
        default:
            return nil
        }
    }

    private func label(for type: String) -> String {
        switch type {
        case "anthropic": return "Anthropic"
        case "openai": return "OpenAI"
        case "bedrock": return "AWS Bedrock"
        case "ollama": return "Ollama"
        default: return type.capitalized
        }
    }

    /// Pre-fill from the existing row. Only id + connector type are known from
    /// the connections list; secret-free config fields are entered fresh.
    private func prefill() {
        if case .existing(let c) = target {
            id = c.id
            if ConnectionConfigInput.allConnectorTypes.contains(c.connectorType) {
                connectorType = c.connectorType
            }
        }
    }

    private func buildConfig() -> ConnectionConfigInput {
        let base = trimmedOrNil(baseURL)
        let ct = UInt64(connectTimeout.trimmingCharacters(in: .whitespaces))
        let st = UInt64(streamTimeout.trimmingCharacters(in: .whitespaces))
        let mt = UInt64(maxTokens.trimmingCharacters(in: .whitespaces))
        switch connectorType {
        case "openai":
            return .openai(baseURL: base, apiKeyEnv: trimmedOrNil(apiKeyEnv),
                           connectTimeoutSecs: ct, streamTimeoutSecs: st, maxContextTokens: mt)
        case "bedrock":
            return .bedrock(awsProfile: trimmedOrNil(awsProfile), region: trimmedOrNil(region),
                            baseURL: base, connectTimeoutSecs: ct, streamTimeoutSecs: st, maxContextTokens: mt)
        case "ollama":
            return .ollama(baseURL: base, connectTimeoutSecs: ct, streamTimeoutSecs: st,
                           keepWarm: keepWarm, maxContextTokens: mt)
        default:
            return .anthropic(baseURL: base, apiKeyEnv: trimmedOrNil(apiKeyEnv),
                              connectTimeoutSecs: ct, streamTimeoutSecs: st, maxContextTokens: mt)
        }
    }

    private func save() async {
        let slug = id.trimmingCharacters(in: .whitespaces)
        guard !slug.isEmpty else { return }
        saving = true
        defer { saving = false }
        let config = buildConfig()
        do {
            if isNew {
                try await model.core.createConnection(id: slug, config: config)
            } else {
                try await model.core.updateConnection(id: slug, config: config)
            }
            // Store any directly-entered credential in the daemon's secret store.
            // Blank = leave the existing secret untouched.
            if let credential = credentialValue {
                try await model.core.setConnectionSecret(id: slug, credential: credential)
            }
            dismiss()
        } catch {
            errorText = "\(error)"
        }
    }

    private func trimmedOrNil(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
