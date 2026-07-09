import AVFoundation

/// Native text-to-speech for Adele's spoken replies. The reducer emits `speak`
/// view-events (one short sentence each) when the conversation's Adele-output
/// level is on; this turns them into `AVSpeechSynthesizer` utterances. The GTK/
/// KDE clients route speech to a voice daemon; on macOS we synthesize in-process.
@MainActor
final class Speaker {
    private let synth = AVSpeechSynthesizer()

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.prefersAssistiveTechnologySettings = false
        synth.speak(utterance)  // queues; sentences play in arrival order
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
    }
}
