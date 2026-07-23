import SwiftUI

/// Privacy settings: the local "Share device info with the assistant" opt-out
/// (#549). Purely local — the preference is persisted in `UserDefaults` and
/// staged on the Rust core, which applies it when the *next* connection builds
/// its config. That timing is spelled out in the footer rather than papered over
/// by dropping the live socket: reconnecting mid-conversation would interrupt a
/// streaming reply for a setting whose whole point is the next turn's prompt.
struct PrivacySettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Share device info with the assistant", isOn: $model.shareClientContext)
            } header: {
                Text("Device context")
            } footer: {
                Text("Lets Adele personalize using this Mac's device name, your username and home folder, the hostname, time zone, and OS. When off, none of it is sent.")
            }

            Section {
                Label(
                    model.connected
                        ? "Takes effect the next time this app connects."
                        : "Applied when this app next connects.",
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
