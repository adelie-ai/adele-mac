import AVFoundation

/// Native text-to-speech for Adele's spoken replies. The reducer emits `speak`
/// view-events (one short sentence each) when the conversation's Adele-output
/// level is on; this turns them into `AVSpeechSynthesizer` utterances. The GTK/
/// KDE clients synthesize with on-device neural models (Kokoro / Piper) via the
/// voice daemon; on macOS we use the system `AVSpeechSynthesizer` and let the
/// user pick from the installed voices (see Voice settings).
@MainActor
final class Speaker {
    private let synth = AVSpeechSynthesizer()

    /// Speak `text` with the chosen voice/rate/pitch. `voiceIdentifier` nil ⇒
    /// system default. `rate` is an `AVSpeechUtterance` rate (0…1, ~0.5 default);
    /// `pitch` is a pitch multiplier (0.5…2.0, 1.0 default).
    func speak(_ text: String, voiceIdentifier: String?, rate: Float, pitch: Float) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.prefersAssistiveTechnologySettings = false
        if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        }
        utterance.rate = rate
        utterance.pitchMultiplier = pitch
        synth.speak(utterance)  // queues; sentences play in arrival order
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
    }
}
