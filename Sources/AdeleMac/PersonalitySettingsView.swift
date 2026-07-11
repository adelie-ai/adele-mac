import AdeleCore
import SwiftUI

/// Editor for Adele's global personality dials — the "Expressive 7" traits, each
/// set to one of five levels (Never…Always). Reads via `GetConfig` and writes via
/// `SetConfig` over the management bridge, so it requires an active connection.
///
/// Standalone (wired into `SettingsView`'s `TabView` by the app); it holds its own
/// loaded state rather than going through `AppModel`, mirroring how `KnowledgeView`
/// drives `model.core` directly. Suggested tab: `Label("Personality", systemImage:
/// "theatermasks")`.
struct PersonalitySettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var personality = Personality()
    @State private var loaded = false
    @State private var errorText: String?

    /// The 7 dials paired with their writable key path. Lives here (a `@MainActor`
    /// View) rather than on `Personality` because `WritableKeyPath` isn't
    /// `Sendable` and `Personality` crosses actor boundaries.
    private let traits: [(name: String, keyPath: WritableKeyPath<Personality, String?>)] = [
        ("professionalism", \.professionalism),
        ("warmth", \.warmth),
        ("directness", \.directness),
        ("enthusiasm", \.enthusiasm),
        ("humor", \.humor),
        ("sarcasm", \.sarcasm),
        ("pretentiousness", \.pretentiousness),
    ]

    var body: some View {
        Form {
            if !model.connected {
                Text("Connect to tune Adele's personality.")
                    .foregroundStyle(.secondary)
            } else if !loaded {
                Text("Loading…").foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach(traits, id: \.name) { trait in
                        Picker(trait.name.capitalized, selection: binding(for: trait.keyPath)) {
                            ForEach(Personality.levels, id: \.self) { level in
                                Text(level.capitalized).tag(level)
                            }
                        }
                    }
                } header: {
                    Text("Disposition")
                } footer: {
                    Text("These set Adele's initial disposition. She still adapts to the conversation — the levels are a starting point, not a rulebook.")
                }
            }
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }
            if model.connected {
                Button("Refresh") { Task { await load() } }
            }
        }
        .formStyle(.grouped)
        .task { await load() }
    }

    /// A two-way binding for one dial: reads the loaded level (falling back to a
    /// neutral default before the daemon's value has arrived) and, on change,
    /// updates local state and persists just that dial.
    private func binding(for keyPath: WritableKeyPath<Personality, String?>) -> Binding<String> {
        Binding(
            get: { personality[keyPath: keyPath] ?? "sometimes" },
            set: { newLevel in
                personality[keyPath: keyPath] = newLevel
                save(keyPath, newLevel)
            }
        )
    }

    private func load() async {
        guard model.connected else { return }
        errorText = nil
        do {
            personality = try await model.core.getPersonality()
            loaded = true
        } catch {
            errorText = "\(error)"
        }
    }

    /// Persist a single changed dial (a partial `SetConfig` — the daemon merges
    /// it into the stored personality, leaving the other dials untouched).
    private func save(_ keyPath: WritableKeyPath<Personality, String?>, _ level: String) {
        var change = Personality()
        change[keyPath: keyPath] = level
        Task {
            do {
                try await model.core.setPersonality(change)
            } catch {
                errorText = "\(error)"
            }
        }
    }
}
