import AdeleCore
import SwiftUI

/// Per-conversation personality override editor (issue #227, Phase 2).
///
/// Pins some or all of the "Expressive 7" dials for a SINGLE conversation,
/// overriding Adele's global personality for that conversation only. Each dial
/// offers "Default (global)" plus the five levels (Never…Always): leaving a dial
/// on "Default (global)" inherits the global value; picking a level pins it. Save
/// sends only the pinned subset via `SetConversationPersonality`; leaving every
/// dial on default and saving clears the override.
///
/// Standalone sheet: it holds its own draft state and drives `model.core`
/// directly (mirroring `PersonalitySettingsView`). The chat toolbar presents it
/// with `.sheet { ConversationPersonalitySheet(conversationID: id) }`.
struct ConversationPersonalitySheet: View {
    /// The conversation whose personality is being overridden.
    let conversationID: String

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// The draft override: a `nil` dial means "Default (global)" (inherit); a
    /// non-nil dial pins that trait. Sent as-is — only pinned dials hit the wire.
    @State private var personality = Personality()
    @State private var saving = false
    @State private var errorText: String?

    /// Sentinel `tag` for the "Default (global)" picker option. Empty string is
    /// never a valid `PersonalityLevel`, so it unambiguously maps to `nil`.
    private static let defaultTag = ""

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
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(traits, id: \.name) { trait in
                        Picker(trait.name.capitalized, selection: binding(for: trait.keyPath)) {
                            Text("Default (global)").tag(Self.defaultTag)
                            Divider()
                            ForEach(Personality.levels, id: \.self) { level in
                                Text(level.capitalized).tag(level)
                            }
                        }
                    }
                } header: {
                    Text("Conversation personality")
                } footer: {
                    Text("Pins dials for this conversation only, overriding Adele's global personality. Dials left on \"Default (global)\" inherit the global value; clearing every dial removes the override.")
                }
                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Reset to global") { personality = Personality() }
                    .disabled(saving)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || !model.connected)
            }
            .padding()
        }
        .frame(minWidth: 420, minHeight: 460)
    }

    /// A two-way binding for one dial: maps `nil` ↔ the "Default (global)"
    /// sentinel tag, and a level string to itself.
    private func binding(for keyPath: WritableKeyPath<Personality, String?>) -> Binding<String> {
        Binding(
            get: { personality[keyPath: keyPath] ?? Self.defaultTag },
            set: { newValue in
                personality[keyPath: keyPath] =
                    (newValue == Self.defaultTag) ? nil : newValue
            }
        )
    }

    /// Persist the pinned subset (only non-nil dials are sent). An all-default
    /// draft clears the override. Dismisses on success.
    private func save() {
        guard model.connected else {
            errorText = "Connect to override this conversation's personality."
            return
        }
        saving = true
        errorText = nil
        Task {
            do {
                try await model.core.setConversationPersonality(
                    conversationID: conversationID, personality)
                dismiss()
            } catch {
                errorText = "\(error)"
            }
            saving = false
        }
    }
}
