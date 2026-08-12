import Foundation
import Testing

@testable import AdeleCore

/// Spec for what one callback from a speech-recognition task means.
///
/// A task reports a transcript, an error, or both, and it marks the last report
/// of the task as final. Which of those the caller treats as speech, as the end
/// of the session, and as the end of only the task is the decision that used to
/// live inside the callback closure, where nothing could reach it.
@Suite struct DictationTaskEventTests {
    /// The ordinary case: words heard so far, more to come.
    @Test func aPartialTranscriptIsSpeech() {
        #expect(
            dictationTaskEvent(transcript: "book the", isFinal: false, errorMessage: nil)
                == .speech("book the")
        )
    }

    /// A task stops on its own after about a minute of audio. The person asked
    /// for nothing, so this ends the task and not the session.
    @Test func aFinalTranscriptIsARolloverAndNotAnEnding() {
        #expect(
            dictationTaskEvent(transcript: "book the flight", isFinal: true, errorMessage: nil)
                == .rollover(finalTranscript: "book the flight")
        )
    }

    /// The final transcript must not arrive as speech. It revises words already
    /// reported, and treating it as new speech restarts the silence clock at the
    /// moment the microphone is due to close.
    @Test func aFinalTranscriptIsNeverReportedAsSpeech() {
        let event = dictationTaskEvent(
            transcript: "book the flight", isFinal: true, errorMessage: nil
        )
        #expect(event != .speech("book the flight"))
    }

    /// An error ends the session, and takes any words the same callback carried
    /// with it, because the composer keeps what it was last given.
    @Test func anErrorEndsTheSession() {
        #expect(
            dictationTaskEvent(transcript: "book the", isFinal: false, errorMessage: "no network")
                == .end(transcript: "book the", message: "no network")
        )
    }

    /// An error with no transcript still ends the session.
    @Test func anErrorWithNoTranscriptEndsTheSession() {
        #expect(
            dictationTaskEvent(transcript: nil, isFinal: false, errorMessage: "no network")
                == .end(transcript: nil, message: "no network")
        )
    }

    /// An error wins over the final mark. A task that fails as it finishes has
    /// failed, and starting another one would fail the same way.
    @Test func anErrorOnAFinalResultEndsTheSessionRatherThanRollingOver() {
        #expect(
            dictationTaskEvent(transcript: "book the", isFinal: true, errorMessage: "no network")
                == .end(transcript: "book the", message: "no network")
        )
    }

    /// A callback with neither words nor a fault asks for nothing.
    @Test func anEmptyCallbackDoesNothing() {
        #expect(
            dictationTaskEvent(transcript: nil, isFinal: false, errorMessage: nil) == .nothing
        )
    }

    /// A task can finish having heard nothing. It is still a rollover, so the
    /// microphone stays on and the silence timers decide what happens next.
    @Test func aFinalResultWithNoTranscriptIsStillARollover() {
        #expect(
            dictationTaskEvent(transcript: nil, isFinal: true, errorMessage: nil)
                == .rollover(finalTranscript: nil)
        )
    }
}
