import AdeleCore
import SwiftUI

/// The Settings (⌘,) window: model purposes + configured connections. These use
/// the generic management command bridge (`send_command`) over the live
/// connection, so they require an active connection.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            PurposesSettings()
                .tabItem { Label("Purposes", systemImage: "target") }
            ConnectionsSettings()
                .tabItem { Label("Connections", systemImage: "server.rack") }
        }
        .frame(width: 540, height: 400)
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
        guard let config = model.purpose(for: kind) else { return "Default" }
        return config.model
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
            .disabled(model.models.isEmpty)
        }
    }
}

private struct ConnectionsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            if !model.connected {
                Text("Connect to view configured connections.")
                    .foregroundStyle(.secondary)
            } else if model.connections.isEmpty {
                Text(model.settingsLoading ? "Loading…" : "No connections configured.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.connections) { connection in
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
        }
        .formStyle(.grouped)
    }
}
