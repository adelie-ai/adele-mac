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
    /// The daemon's last reported dials — the `lastKnown` fed to
    /// `PersonalityWrite.planned`. Kept separate from the editable `personality`
    /// so a dial reconciled to server state is recognised as a no-op and never
    /// re-emitted (the durable fix from #10/#13; a suppression flag does not
    /// survive a reconcile).
    @State private var serverPersonality = Personality()
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
                        Picker(trait.name.capitalized, selection: binding(for: trait)) {
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
    ///
    /// The write is routed through `PersonalityWrite.planned`, which drops any
    /// change whose result equals the daemon's last reported level. A reconcile
    /// (or any future refresh/reconnect that assigns this dial from server
    /// state) therefore cannot emit a write — the structural guard from
    /// #10/#13, independent of when a change notification fires.
    private func binding(
        for trait: (name: String, keyPath: WritableKeyPath<Personality, String?>)
    ) -> Binding<String> {
        Binding(
            get: { personality[keyPath: trait.keyPath] ?? "sometimes" },
            set: { newLevel in
                personality[keyPath: trait.keyPath] = newLevel
                guard let level = PersonalityWrite.planned(
                    trait: trait.name,
                    desired: newLevel,
                    lastKnown: serverPersonality[keyPath: trait.keyPath]
                ) else { return }
                save(trait.keyPath, level)
            }
        )
    }

    private func load() async {
        guard model.connected else { return }
        errorText = nil
        do {
            let loadedPersonality = try await model.core.getPersonality()
            personality = loadedPersonality
            serverPersonality = loadedPersonality
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
                // The daemon now holds this level; record it as last-known so a
                // subsequent reconcile to the same value is dropped as a no-op.
                serverPersonality[keyPath: keyPath] = level
            } catch {
                errorText = "\(error)"
            }
        }
    }
}
