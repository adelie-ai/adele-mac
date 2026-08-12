import Foundation

// What one callback from a speech-recognition task means.
//
// A task reports the transcript of the whole task so far, an error, or both,
// and it marks the last report of a task as final. Three different things must
// happen to those, and telling them apart correctly is what keeps one dictation
// session alive across several messages.
//
// Not here: the recognizer, the microphone, or the callbacks themselves. That
// is `Dictation` in the app target. This is the decision it makes, kept pure so
// it can be tested without a microphone.

/// What one callback from a recognition task asks the caller to do.
public enum DictationTaskEvent: Sendable, Hashable {
    /// Words heard since the task began. They replace the transcript before
    /// them, and they are speech, so they restart the silence clock.
    case speech(String)
    /// The task reached the framework's own limit and another must take its
    /// place. The session continues, with the microphone still open.
    ///
    /// `finalTranscript` is the last transcript of the task, where it revises
    /// words it already reported. It is not new speech, so it does not restart
    /// the silence clock.
    case rollover(finalTranscript: String?)
    /// The session is over. `transcript` is any words the same callback still
    /// carried, which the composer keeps.
    case end(transcript: String?, message: String)
    /// The callback carried nothing to act on.
    case nothing
}

/// Read one recognition-task callback.
///
/// The order of the tests is the whole decision:
///
/// - An error wins over the final mark. A task that fails as it finishes has
///   failed, and starting another one would fail the same way.
/// - A final result is a rollover, not an ending. A task stops on its own after
///   about a minute of audio, and the person asked for nothing. A stop the
///   person asked for never reaches here, because it drops its task first.
/// - A final result is never speech. It revises words already reported, and
///   treating it as new speech restarts the silence clock at the moment the
///   microphone is due to close.
public func dictationTaskEvent(
    transcript: String?,
    isFinal: Bool,
    errorMessage: String?
) -> DictationTaskEvent {
    if let errorMessage {
        return .end(transcript: transcript, message: errorMessage)
    }
    if isFinal {
        return .rollover(finalTranscript: transcript)
    }
    if let transcript {
        return .speech(transcript)
    }
    return .nothing
}
