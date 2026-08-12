import AVFoundation
import Speech

/// Native speech-to-text dictation via `SFSpeechRecognizer` + `AVAudioEngine`.
/// Partial transcripts stream to `onText` (main queue) as the user speaks; the
/// caller drives the mic button and decides when to send. The Linux client uses
/// on-device Whisper; macOS uses whichever recognizer the framework picks, which
/// is not necessarily the local one: `requiresOnDeviceRecognition` is left at
/// its default of `false`, so audio can go to Apple's servers, and server
/// recognition is subject to a documented per-device daily limit. Both the limit
/// and a lost network show up here as a recognizer that is not available.
///
/// A recognition task reports the transcript of the **whole task**, not the
/// words since the last callback, and it revises words it has already reported
/// as later context arrives. So a caller that consumes the transcript - by
/// sending it - must call ``restart()``, or the next callback hands back the
/// words it already consumed. The microphone keeps running across a restart,
/// because the mic button is a toggle and dictating several messages in a row is
/// the point of it.
///
/// One task does not run forever. The framework ends a recognition task after
/// about a minute of audio, delivering a final result, and this session ends
/// with it - the caller sees `onEnd` with no message, as it would for a normal
/// stop. Each ``restart()`` begins a new task and starts that clock again, so
/// the limit is reached between messages sent more than about a minute apart,
/// not during one of them.
///
/// Requires `NSMicrophoneUsageDescription` + `NSSpeechRecognitionUsageDescription`
/// in the app's Info.plist (see scripts/build-app.sh / run-app.sh).
final class Dictation: NSObject, @unchecked Sendable {
    private let recognizer = SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    /// The live request. Read and written on the main queue only; the audio tap
    /// never touches it, because each tap closure holds the one request it was
    /// installed for.
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var isTapped = false
    /// Which transcript is current. Incremented by every ``listen(_:)``, so a
    /// callback can tell whether the task it belongs to has been replaced. A
    /// counter rather than the request itself, because the request is not
    /// `Sendable` and must not cross to the main queue.
    private var session = 0

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
        listen(recognizer)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            cleanup()
            emitEnd("Couldn't start the microphone: \(error.localizedDescription)")
            return
        }
        isRecording = true
    }

    /// Start a fresh transcript without stopping the microphone.
    ///
    /// The caller resets the session when it consumes the transcript - on send -
    /// so the next transcript begins empty rather than carrying the words that
    /// were just sent. A no-op when not recording, so a send with the microphone
    /// off costs nothing.
    ///
    /// The running task is dropped first, and unconditionally. A restart that
    /// gave up before that - because the recognizer is not available at this
    /// moment - would leave the old task running with the sent words still in
    /// its transcript, and its next partial would write them back into the
    /// cleared composer (adele-mac#42). Availability is transient: it drops for
    /// the network, and it is how the daily server-recognition limit appears. So
    /// a restart that cannot start a task ends the session with a message,
    /// rather than leaving a mic button that records nothing.
    func restart() {
        guard isRecording else { return }
        invalidateTask()
        guard let recognizer, recognizer.isAvailable else {
            finish("Dictation stopped: speech recognition is not available right now.")
            return
        }
        listen(recognizer)
    }

    /// Drop the running task and disown the callbacks it has yet to deliver.
    ///
    /// Cancel rather than end the audio: `endAudio` asks for a final result
    /// covering the words already spoken, and on the send path those are the
    /// words just sent. The session counter moves here, so a callback already in
    /// flight is discarded on arrival.
    private func invalidateTask() {
        session += 1
        task?.cancel()
        task = nil
        request = nil
    }

    func stop() { finish(nil) }

    /// Point a new request, tap and task at the microphone.
    ///
    /// The tap captures `request` rather than reading a property, so the audio
    /// thread never sees state that ``restart()`` mutates on the main queue.
    /// Swapping the tap is what makes a restart safe while the engine runs.
    private func listen(_ recognizer: SFSpeechRecognizer) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request
        session += 1
        let session = self.session

        let input = engine.inputNode
        if isTapped { input.removeTap(onBus: 0) }
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        isTapped = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result.map { $0.bestTranscription.formattedString }
            let isFinal = result?.isFinal ?? false
            let message = error?.localizedDescription
            DispatchQueue.main.async {
                guard let self else { return }
                // A callback from a task that has since been replaced carries the
                // transcript it was replaced for; delivering it would put the
                // sent words back in the composer.
                guard self.session == session else { return }
                if let text { self.onText?(text) }
                if isFinal { self.finish(nil) }
                if let message { self.finish(message) }
            }
        }
    }

    private func finish(_ errorMessage: String?) {
        guard isRecording else { return }
        cleanup()
        emitEnd(errorMessage)
    }

    private func cleanup() {
        engine.stop()
        if isTapped {
            engine.inputNode.removeTap(onBus: 0)
            isTapped = false
        }
        request?.endAudio()
        invalidateTask()
        isRecording = false
    }

    private func emitEnd(_ message: String?) {
        DispatchQueue.main.async { self.onEnd?(message) }
    }
}
