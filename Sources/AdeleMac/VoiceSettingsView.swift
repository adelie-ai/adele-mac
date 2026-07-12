import AVFoundation
import SwiftUI

/// Voice (text-to-speech) settings: pick the system voice Adele speaks with,
/// plus rate/pitch. Purely local (no daemon needed). macOS synthesizes speech
/// via `AVSpeechSynthesizer`; higher-quality neural voices can be downloaded in
/// System Settings → Accessibility → Spoken Content → System Voice → Manage
/// Voices, and then appear here.
struct VoiceSettingsView: View {
    @Environment(AppModel.self) private var model

    // Installed voices, sorted by language then name.
    private var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Voice", selection: Binding(
                    get: { model.voiceIdentifier ?? "" },
                    set: { model.voiceIdentifier = $0.isEmpty ? nil : $0 }
                )) {
                    Text("System Default").tag("")
                    ForEach(voices, id: \.identifier) { voice in
                        Text(label(for: voice)).tag(voice.identifier)
                    }
                }
            } header: {
                Text("Voice")
            } footer: {
                Text("Download higher-quality voices in System Settings → Accessibility → Spoken Content → Manage Voices; they appear here.")
            }

            Section("Speech") {
                VStack(alignment: .leading) {
                    Text("Rate")
                    Slider(value: $model.speechRate,
                           in: Double(AVSpeechUtteranceMinimumSpeechRate)...Double(AVSpeechUtteranceMaximumSpeechRate))
                }
                VStack(alignment: .leading) {
                    Text("Pitch")
                    Slider(value: $model.speechPitch, in: 0.5...2.0)
                }
            }

            Section {
                Button {
                    model.previewVoice()
                } label: {
                    Label("Preview", systemImage: "play.circle")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func label(for voice: AVSpeechSynthesisVoice) -> String {
        let quality: String
        switch voice.quality {
        case .premium: quality = " · Premium"
        case .enhanced: quality = " · Enhanced"
        default: quality = ""
        }
        return "\(voice.name) — \(voice.language)\(quality)"
    }
}
