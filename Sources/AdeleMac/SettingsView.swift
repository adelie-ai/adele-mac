import AdeleCore
import SwiftUI

/// The Settings (⌘,) window: model purposes, LLM connections, MCP servers, and
/// personality. These use the generic management command bridge (`send_command`)
/// over the live connection, so they require an active connection.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            PurposesSettings()
                .tabItem { Label("Purposes", systemImage: "target") }
            ConnectionsEditorView()
                .tabItem { Label("Connections", systemImage: "server.rack") }
            McpSettingsView()
                .tabItem { Label("MCP", systemImage: "puzzlepiece.extension") }
            PersonalitySettingsView()
                .tabItem { Label("Personality", systemImage: "theatermasks") }
            VoiceSettingsView()
                .tabItem { Label("Voice", systemImage: "waveform") }
            PrivacySettingsView()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 560, height: 460)
        .task { model.loadSettings() }
    }
}

private struct PurposesSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            if !model.connected {
                Text("Connect to manage model purposes.")
                    .foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach(AdeleCore.purposeKinds, id: \.self) { kind in
                        PurposeRow(kind: kind)
                    }
                } header: {
                    Text("Model assignments")
                } footer: {
                    Text("“Interactive” is the model Adele chats with. Changing it fixes the default for new conversations.")
                }
                if let error = model.settingsError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Button("Refresh") { model.loadSettings() }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PurposeRow: View {
    @Environment(AppModel.self) private var model
    let kind: String

    private var currentLabel: String {
        PurposeWrite.displayLabel(for: model.purpose(for: kind))
    }

    var body: some View {
        HStack {
            Text(kind.capitalized)
            Spacer()
            Menu {
                ForEach(model.modelsByConnection, id: \.label) { group in
                    Section(group.label) {
                        ForEach(group.listings) { listing in
                            Button(listing.model.displayName) {
                                model.setPurpose(
                                    kind,
                                    connectionID: listing.connectionId,
                                    modelID: listing.model.id
                                )
                            }
                        }
                    }
                }
            } label: {
                Text(currentLabel).foregroundStyle(.secondary)
            }
            .fixedSize()
            // A row whose model list is unavailable must not be writable at all
            // (adele-gtk#142): with no listings there is nothing this UI could
            // honestly bind, and the only thing left to pick would be a
            // sentinel the user never chose.
            .disabled(model.models.isEmpty)
        }
    }
}

// The read-only connections tab was superseded by the editable
// `ConnectionsEditorView` (create/update/delete). `AppModel.connections` /
// `loadSettings()` still back the Purposes tab's model list.
