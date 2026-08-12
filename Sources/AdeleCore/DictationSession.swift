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

    public init() {}

    /// The composer text this session's state produces.
    public var composerText: String { dictationDraft(base: base, transcript: transcript) }

    /// Start a session on top of the composer text that is there now.
    public func begin(base: String, conversationID: String?) {
        self.base = base
        self.conversationID = conversationID
        transcript = ""
    }

    /// Take the recognizer's transcript, and answer with the composer text.
    @discardableResult
    public func receive(transcript: String) -> String {
        self.transcript = transcript
        return composerText
    }

    /// The composer was sent. Both halves go, together.
    ///
    /// Dropping the base alone would leave the sent words in the transcript, and
    /// the next callback would write them back into the cleared composer
    /// (adele-mac#42). The caller must also restart the recognizer, which holds
    /// the same words.
    public func consumeOnSend() {
        base = dictationBaseAfterSend()
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
    public func rebaseIfExternal(composer text: String) -> Bool {
        guard text != composerText else { return false }
        base = text
        transcript = ""
        return true
    }

    /// The session is over.
    public func end() {
        base = ""
        transcript = ""
        conversationID = nil
    }
}
