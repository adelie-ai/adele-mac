import AVFoundation
import Speech

/// Native speech-to-text dictation via `SFSpeechRecognizer` + `AVAudioEngine`.
/// Partial transcripts stream to `onText` (main queue) as the user speaks; the
/// caller drives the mic button and decides when to send. The Linux client uses
/// on-device Whisper; on macOS we use Apple's on-device recognizer.
///
/// Requires `NSMicrophoneUsageDescription` + `NSSpeechRecognitionUsageDescription`
/// in the app's Info.plist (see scripts/build-app.sh / run-app.sh).
final class Dictation: NSObject, @unchecked Sendable {
    private let recognizer = SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Latest transcript (main queue).
    var onText: ((String) -> Void)?
    /// Recording ended (main queue); non-nil message on error.
    var onEnd: ((String?) -> Void)?

    private(set) var isRecording = false

    /// Request mic + speech-recognition permission. True only if both granted.
    func requestAuthorization() async -> Bool {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() {
        guard !isRecording else { return }
        guard let recognizer, recognizer.isAvailable else {
            emitEnd("Speech recognition is unavailable.")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            cleanup()
            emitEnd("Couldn't start the microphone: \(error.localizedDescription)")
            return
        }
        isRecording = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async { self.onText?(text) }
                if result.isFinal { self.finish(nil) }
            }
            if let error { self.finish(error.localizedDescription) }
        }
    }

    func stop() { finish(nil) }

    private func finish(_ errorMessage: String?) {
        guard isRecording else { return }
        cleanup()
        emitEnd(errorMessage)
    }

    private func cleanup() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false
    }

    private func emitEnd(_ message: String?) {
        DispatchQueue.main.async { self.onEnd?(message) }
    }
}
