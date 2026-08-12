import Foundation
import Observation

/// The state of one dictation session: the composer text it started from, the
/// transcript it holds now, and the conversation it belongs to.
///
/// The mic button is a toggle, so a session outlives one message. Its state is
/// therefore not a property of one draw of the composer, and it is read by
/// long-lived callbacks from the recognizer. A reference type keeps those
/// callbacks on the live values rather than on whatever a captured view struct
/// can still see.
///
/// The session owns when the state changes; ``dictationDraft(base:transcript:)``
/// stays the rule for what the two parts join into. Not here: the recognizer, or
/// the microphone. That is `Dictation` in the app target.
@Observable
public final class DictationSession {
    /// Composer text from before the transcript: what the person typed, what
    /// something other than dictation put there, and the words of any earlier
    /// recognition task in this session.
    public private(set) var base: String = ""
    /// The live recognition task's transcript, whole. Each one replaces the last.
    public private(set) var transcript: String = ""
    /// The conversation this session started in.
    ///
    /// The draft, the voice-input flag and the words themselves belong to that
    /// conversation, and it is not always the selected one: a conversation
    /// switch leaves the session pointing at where it began until it ends.
    public private(set) var conversationID: String?
    /// When the transcript last changed.
    ///
    /// A silence is measured from here, because a recognizer streams partial
    /// results while a person speaks and goes quiet when they stop. Only speech
    /// moves it: typing, a recalled message and a task rollover are not speech,
    /// and the stop timer exists to close a microphone nobody speaks into.
    ///
    /// The instant comes from a clock that only counts forward, not from a
    /// `Date`. A wall clock can step - a time-server correction, a manual change
    /// - and a step forward fires a timer early while a step back stalls it. Of
    /// the two monotonic clocks this is the suspending one, which does not count
    /// time while the machine sleeps: a sleeping machine hears nothing, so that
    /// time is not a silence the person let pass, and counting it would send a
    /// half-dictated message on the first tick after a wake.
    ///
    /// The caller supplies the instant rather than the session reading a clock,
    /// so the timers are testable without waiting for one.
    public private(set) var lastChangeAt: SuspendingClock.Instant
    /// Words dictated in this session that a task rollover moved into the base.
    ///
    /// They are no longer in ``transcript``, and a pause must still send them.
    private var carriedDictation = false

    public init(at now: SuspendingClock.Instant = SuspendingClock.now) {
        lastChangeAt = now
    }

    /// How long the transcript has been unchanged, as of `now`, in seconds.
    public func silence(now: SuspendingClock.Instant) -> TimeInterval {
        lastChangeAt.duration(to: now).seconds
    }

    /// Whether anything has actually been dictated in this session.
    ///
    /// A silence timer that sends asks this, so that typed text alone is never
    /// sent by a pause. It counts the words a task rollover banked as well as
    /// the ones the live task holds.
    public var hasTranscript: Bool {
        carriedDictation || !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The composer text this session's state produces.
    public var composerText: String { dictationDraft(base: base, transcript: transcript) }

    /// Start a session on top of the composer text that is there now.
    public func begin(base: String, conversationID: String?, at now: SuspendingClock.Instant) {
        self.base = base
        self.conversationID = conversationID
        transcript = ""
        carriedDictation = false
        lastChangeAt = now
    }

    /// Take the recognizer's transcript, and answer with the composer text.
    /// Only a transcript that differs restarts the silence clock. The recognizer
    /// can report the same words again, and counting that as speech would keep a
    /// silence from ever completing.
    @discardableResult
    public func receive(transcript: String, at now: SuspendingClock.Instant) -> String {
        if transcript != self.transcript {
            self.transcript = transcript
            lastChangeAt = now
        }
        return composerText
    }

    /// The composer was sent. Both halves go, together.
    ///
    /// Dropping the base alone would leave the sent words in the transcript, and
    /// the next callback would write them back into the cleared composer
    /// (adele-mac#42). The caller must also restart the recognizer, which holds
    /// the same words.
    public func consumeOnSend(at now: SuspendingClock.Instant) {
        base = dictationBaseAfterSend()
        transcript = ""
        carriedDictation = false
        lastChangeAt = now
    }

    /// One recognition task ended and the next begins: keep its words.
    ///
    /// A task stops on its own after about a minute of audio. The person asked
    /// for nothing, so the session continues, but the next task reports a
    /// transcript of its own from empty. The words heard so far therefore move
    /// into the base, where the next transcript adds to them instead of
    /// replacing them. The composer text does not change, and neither does the
    /// silence clock: a rollover is not speech.
    public func commitOnTaskRollover() {
        carriedDictation = hasTranscript
        base = composerText
        transcript = ""
    }

    /// Adopt composer text that this session did not write, and report whether
    /// it was such text.
    ///
    /// A recalled queued message, a failed prompt offered back, and text typed
    /// by hand all reach the composer this way. Each is a new base: written over
    /// by the next transcript otherwise. `true` means the caller must restart
    /// the recognizer as well, because the transcript dropped here is still held
    /// by the running task.
    ///
    /// The silence clock does not move. None of these is speech, and the timer
    /// that closes an unattended microphone must not be held open by typing
    /// (adele-mac#47).
    public func rebaseIfExternal(composer text: String) -> Bool {
        guard text != composerText else { return false }
        base = text
        transcript = ""
        carriedDictation = false
        return true
    }

    /// Measure the silence from `now` instead of from the last words heard.
    ///
    /// A changed setting must not fire against quiet that was already banked:
    /// turning "send after a pause" on after twenty seconds of silence must not
    /// send at once.
    public func restartSilenceClock(at now: SuspendingClock.Instant) {
        lastChangeAt = now
    }

    /// The session is over.
    public func end() {
        base = ""
        transcript = ""
        carriedDictation = false
        conversationID = nil
    }
}

extension Duration {
    /// This duration in seconds, the unit the silence intervals are set in.
    fileprivate var seconds: TimeInterval {
        let (whole, attoseconds) = components
        return TimeInterval(whole) + TimeInterval(attoseconds) / 1e18
    }
}
