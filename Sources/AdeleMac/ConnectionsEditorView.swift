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
                // The daemon's auth-aware preflight reason ("Azure connection
                // needs a resource endpoint (base_url) and a deployment
                // (model)", …) is shown verbatim — never reduced to a red dot.
                if let detail = connection.statusDetail {
                    Text("\(ConnectionConfigInput.displayName(for: connection.connectorType)) — \(detail)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .help(detail)
                } else {
                    Text(ConnectionConfigInput.displayName(for: connection.connectorType))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
    /// All non-secret config fields live in the pure, unit-tested form model.
    @State private var form = ConnectionFormState()
    // Raw credentials entered directly (stored in the daemon's secret store, not
    // in daemon.toml). Blank on edit = keep the existing secret untouched.
    @State private var apiKey = ""
    @State private var awsAccessKey = ""
    @State private var awsSecretKey = ""
    @State private var awsSessionToken = ""
    @State private var saving = false
    @State private var errorText: String?
    /// The daemon's preflight verdict for the connection being edited.
    @State private var preflightReason: String?

    private var isNew: Bool {
        if case .new = target { return true }
        return false
    }

    private var connectorType: String { form.connectorType }

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
                    Picker("Connector type", selection: $form.connectorType) {
                        ForEach(ConnectionConfigInput.allConnectorTypes, id: \.self) { type in
                            Text(ConnectionConfigInput.displayName(for: type)).tag(type)
                        }
                    }
                }

                // The daemon refuses to use a connection whose required pieces
                // are missing and says which ones; show that verdict here too so
                // an edit session starts from the actual problem.
                if let preflightReason {
                    Section {
                        Label(preflightReason, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }

                Section {
                    if connectorType == "google" {
                        Picker("Auth mode", selection: $form.googleAuthMode) {
                            ForEach(ConnectionConfigInput.googleAuthModes, id: \.self) { mode in
                                Text(authModeLabel(mode)).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        TextField("GCP project id (project)", text: $form.project)
                        TextField("Vertex region (location), e.g. us-central1", text: $form.location)
                        if form.usesVertexCredentials {
                            TextField("Service-account JSON path (optional — falls back to ADC)",
                                      text: $form.credentialsPath)
                        }
                    }

                    TextField(form.baseURLPrompt, text: $form.baseURL)

                    if connectorType == "azure" {
                        Picker("API surface", selection: $form.apiSurface) {
                            ForEach(ConnectionConfigInput.azureApiSurfaces, id: \.self) { surface in
                                Text(apiSurfaceLabel(surface)).tag(surface)
                            }
                        }
                        .pickerStyle(.segmented)
                        Picker("Auth mode", selection: $form.azureAuthMode) {
                            ForEach(ConnectionConfigInput.azureAuthModes, id: \.self) { mode in
                                Text(authModeLabel(mode)).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        if form.usesAzureApiVersion {
                            TextField("API version (classic surface), e.g. 2024-10-21", text: $form.apiVersion)
                        }
                    }

                    if form.usesApiKey {
                        TextField(form.apiKeyEnvPrompt, text: $form.apiKeyEnv)
                        SecureField(secretPrompt, text: $apiKey)
                    }
                    if connectorType == "bedrock" {
                        TextField("AWS profile (aws_profile)", text: $form.awsProfile)
                        TextField("Region (e.g. us-east-1)", text: $form.region)
                        SecureField("AWS Access Key ID (optional)", text: $awsAccessKey)
                        SecureField("AWS Secret Access Key", text: $awsSecretKey)
                        SecureField("AWS Session Token (optional)", text: $awsSessionToken)
                    }
                    if connectorType == "ollama" {
                        Toggle("Keep model warm (keep_warm)", isOn: $form.keepWarm)
                    }
                } footer: {
                    Text(credentialFooter).font(.caption)
                }

                Section("Advanced (optional)") {
                    TextField("Connect timeout (secs)", text: $form.connectTimeout)
                    TextField("Stream timeout (secs)", text: $form.streamTimeout)
                    TextField("Max context tokens", text: $form.maxTokens)
                }

                if let errorText {
                    // Includes the daemon's own rejection reason (create/update
                    // preflight), so a failed save is never silent.
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
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
        .frame(width: 520, height: 600)
        .onAppear(perform: prefill)
    }

    private var secretPrompt: String {
        isNew ? "API key (optional — stored securely on the daemon)"
              : "API key (re-enter to keep — saving an edit clears the stored key)"
    }

    private func apiSurfaceLabel(_ surface: String) -> String {
        switch surface {
        case "v1": return "v1 (GA)"
        case "classic": return "Classic (deployments path)"
        default: return surface
        }
    }

    private func authModeLabel(_ mode: String) -> String {
        switch mode {
        case "api_key": return connectorType == "google" ? "API key (AI Studio)" : "API key"
        case "entra": return "Entra ID / managed identity"
        case "vertex": return "Vertex AI (ADC / service account)"
        default: return mode
        }
    }

    private var credentialFooter: String {
        // Saving an edit rewrites the connection config, which clears its stored
        // secret coordinate — so on edit the credential must be re-entered to keep it.
        let editNote = isNew ? "" : " Saving this edit clears the stored credential — re-enter it to keep it."
        let apiKeyNote = "Provide the key via an environment variable on the daemon (api_key_env) or by entering it here — stored in the daemon's secret store, never in daemon.toml."
        switch connectorType {
        case "anthropic", "openai", "openrouter":
            return apiKeyNote + editNote
        case "azure":
            let endpointNote = "The resource endpoint is required (e.g. https://<name>.openai.azure.com); the model is the Azure deployment name, chosen in the model picker, not here."
            if form.usesApiKey { return endpointNote + " " + apiKeyNote + editNote }
            return endpointNote + " Entra ID mode authenticates with a managed identity — no key needed."
        case "google":
            if form.usesVertexCredentials {
                return "Vertex AI needs a project and a location. Credentials come from the service-account JSON at the path above, or from Application Default Credentials when it is blank — the path is not a secret."
            }
            return "Gemini API (AI Studio) mode. " + apiKeyNote + editNote
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
        if form.usesApiKey { return trimmedOrNil(apiKey) }
        switch connectorType {
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

    /// Pre-fill from the existing row: id, connector type, and the daemon-echoed
    /// non-secret config (base_url, api_key_env, region, project, timeouts, …).
    /// Secrets are never echoed, so credential fields stay blank (re-enter to
    /// keep). Also carries over the daemon's preflight verdict.
    private func prefill() {
        guard case .existing(let c) = target else { return }
        id = c.id
        preflightReason = c.statusDetail
        if let cfg = c.config {
            form = ConnectionFormState(config: cfg)
        } else if ConnectionConfigInput.allConnectorTypes.contains(c.connectorType) {
            // Older daemons don't echo the config; at least keep the type.
            form = ConnectionFormState(connectorType: c.connectorType)
        }
    }

    private func save() async {
        let slug = id.trimmingCharacters(in: .whitespaces)
        guard !slug.isEmpty else { return }
        saving = true
        defer { saving = false }
        let config = form.build()
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
