import AVFoundation
import Speech

/// Native speech-to-text dictation via `SFSpeechRecognizer` + `AVAudioEngine`.
/// Partial transcripts stream to `onText` (main queue) as the user speaks; the
/// caller drives the mic button and decides when to send. The Linux client uses
/// on-device Whisper; macOS uses whichever recognizer the framework picks, which
/// is not necessarily the local one: `requiresOnDeviceRecognition` is left at
/// its default of `false`, so audio can go to Apple's servers. Apple states two
/// limits on recognition requests, and scopes neither of them to the server: a
/// device may do only so many recognitions in a day, and an app that makes too
/// many requests can be throttled as a whole. Both limits, and a lost network,
/// show up here as a recognizer that is not available.
///
/// A recognition task reports the transcript of the **whole task**, not the
/// words since the last callback, and it revises words it has already reported
/// as later context arrives. So a caller that consumes the transcript - by
/// sending it - must call ``restart()``, or the next callback hands back the
/// words it already consumed. The microphone keeps running across a restart,
/// because the mic button is a toggle and dictating several messages in a row is
/// the point of it.
///
/// One task does not run forever. Apple documents a limit of about a minute of
/// audio, after which the task stops; what it delivers as it stops is not
/// documented, and in practice a final result arrives. The limit is on the task,
/// not on the session, so it is reached in the middle of a sentence as readily
/// as between two messages. A final result that the caller did not ask for
/// therefore rolls the session over rather than ending it: ``onRollover`` tells
/// the caller to bank the transcript it holds, and a new task starts on the same
/// microphone. The mic button, the composer text and the session stay as they
/// are. Only a stop the person asked for, or an error, ends the session.
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
    /// One recognition task reached the framework's limit and another begins in
    /// its place (main queue). The session is not over.
    ///
    /// The caller must bank the transcript it holds: the next task reports its
    /// own transcript from empty, and the words of the task that ended are not
    /// in it.
    var onRollover: (() -> Void)?
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
    func restart() {
        guard isRecording else { return }
        renewTask()
    }

    /// The framework ended the task on its own; keep the session and start
    /// another task in its place.
    ///
    /// A task stops after about a minute of audio, so this arrives while the
    /// person is still dictating and has asked for nothing. Ending the session
    /// here would close a microphone that was left open deliberately, and the
    /// longer silence timer could never reach an interval past that minute. The
    /// caller banks the final transcript first, because the next task reports
    /// its own from empty.
    private func rollOverTask() {
        guard isRecording else { return }
        onRollover?()
        renewTask()
    }

    /// Drop the running task and point a new one at the same microphone.
    ///
    /// Cancel rather than end the audio: `endAudio` asks for a final result
    /// covering the words already spoken, and on the send path those are the
    /// words just sent.
    ///
    /// The old task goes first, and unconditionally. Giving up before that -
    /// because the recognizer is not available at this moment - would leave it
    /// running with the sent words still in its transcript, and its next partial
    /// would write them back into the cleared composer (adele-mac#42).
    /// Availability is transient: it drops for the network, and it is how the
    /// request limits appear. So a renewal that cannot start a task ends the
    /// session with a message, rather than leaving a mic button that records
    /// nothing.
    private func renewTask() {
        invalidateTask()
        guard let recognizer, recognizer.isAvailable else {
            finish("Dictation stopped: speech recognition is not available right now.")
            return
        }
        listen(recognizer)
    }

    /// Drop the running task and disown the callbacks it has yet to deliver.
    ///
    /// The session counter moves here, so a callback already in flight is
    /// discarded on arrival.
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
                if let message {
                    // An error ends the session, and says why.
                    self.finish(message)
                } else if isFinal {
                    // A final result nobody asked for: the framework's own limit
                    // on one task, not a stop. A stop the person asked for goes
                    // through `stop()`, which drops this task and moves the
                    // session counter, so the final result it asks for is
                    // discarded by the guard above and never reaches here.
                    self.rollOverTask()
                }
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
