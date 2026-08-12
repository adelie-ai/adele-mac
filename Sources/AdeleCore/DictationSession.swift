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
    /// Composer text from before the transcript: what the person typed, or what
    /// something other than dictation put there.
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
    /// results while a person speaks and goes quiet when they stop. The caller
    /// supplies the instant rather than the session reading a clock, so the
    /// timers are testable without waiting for one.
    public private(set) var lastChangeAt = Date(timeIntervalSince1970: 0)

    public init() {}

    /// How long the transcript has been unchanged, as of `now`.
    public func silence(now: Date) -> TimeInterval {
        now.timeIntervalSince(lastChangeAt)
    }

    /// Whether anything has actually been dictated in this session.
    ///
    /// A silence timer that sends asks this, so that typed text alone is never
    /// sent by a pause.
    public var hasTranscript: Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The composer text this session's state produces.
    public var composerText: String { dictationDraft(base: base, transcript: transcript) }

    /// Start a session on top of the composer text that is there now.
    public func begin(base: String, conversationID: String?, at now: Date) {
        self.base = base
        self.conversationID = conversationID
        transcript = ""
        lastChangeAt = now
    }

    /// Take the recognizer's transcript, and answer with the composer text.
    /// Only a transcript that differs restarts the silence clock. The recognizer
    /// can report the same words again, and counting that as speech would keep a
    /// silence from ever completing.
    @discardableResult
    public func receive(transcript: String, at now: Date) -> String {
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
    public func consumeOnSend(at now: Date) {
        base = dictationBaseAfterSend()
        transcript = ""
        lastChangeAt = now
    }

    /// Adopt composer text that this session did not write, and report whether
    /// it was such text.
    ///
    /// A recalled queued message, a failed prompt offered back, and text typed
    /// by hand all reach the composer this way. Each is a new base: written over
    /// by the next transcript otherwise. `true` means the caller must restart
    /// the recognizer as well, because the transcript dropped here is still held
    /// by the running task.
    public func rebaseIfExternal(composer text: String, at now: Date) -> Bool {
        guard text != composerText else { return false }
        base = text
        transcript = ""
        lastChangeAt = now
        return true
    }

    /// The session is over.
    public func end() {
        base = ""
        transcript = ""
        conversationID = nil
    }
}
