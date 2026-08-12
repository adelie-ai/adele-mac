import Testing

@testable import AdeleCore

/// Spec for the state one dictation session holds while the microphone is on.
///
/// The mic button is a toggle, so a session outlives one message: it starts from
/// whatever was already in the composer, takes a stream of transcripts that each
/// replace the last, and is consumed when a message is sent. Anything else that
/// writes the composer - a recalled queued message, a restored failed prompt,
/// text typed by hand - becomes the new base, or the next transcript writes over
/// it.
@Suite struct DictationSessionTests {
    /// Dictation adds to the composer rather than taking it over.
    @Test func aSessionStartsFromWhatWasAlreadyTyped() {
        let session = DictationSession()
        session.begin(base: "meeting notes:", conversationID: "c1")
        #expect(session.base == "meeting notes:")
        #expect(session.transcript == "")
        #expect(session.composerText == "meeting notes:")
    }

    /// The recognizer reports the whole task each time and revises words it
    /// already reported, so a transcript replaces the one before it.
    @Test func eachTranscriptReplacesTheOneBefore() {
        let session = DictationSession()
        session.begin(base: "notes:", conversationID: "c1")
        #expect(session.receive(transcript: "call pre") == "notes: call pre")
        #expect(session.receive(transcript: "call Priya") == "notes: call Priya")
        #expect(session.transcript == "call Priya")
    }

    /// A send consumes the composer, so the session keeps neither the typed base
    /// nor the words that went with it.
    @Test func aSendConsumesTheBaseAndTheTranscript() {
        let session = DictationSession()
        session.begin(base: "notes:", conversationID: "c1")
        session.receive(transcript: "call Priya")
        session.consumeOnSend()
        #expect(session.base == "")
        #expect(session.transcript == "")
        #expect(session.composerText == "")
    }

    /// The defect this exists to prevent (#42): after a send, the next
    /// transcript must not put the sent words back in the cleared composer.
    @Test func theTranscriptAfterASendCarriesNoSentWords() {
        let session = DictationSession()
        session.begin(base: "", conversationID: "c1")
        session.receive(transcript: "first message")
        session.consumeOnSend()
        #expect(session.receive(transcript: "second message") == "second message")
    }

    /// The composer text the session itself produced is not an external write,
    /// so a session is never re-based on its own output.
    @Test func theTextTheSessionWroteIsNotExternal() {
        let session = DictationSession()
        session.begin(base: "notes:", conversationID: "c1")
        let written = session.receive(transcript: "call Priya")
        #expect(session.rebaseIfExternal(composer: written) == false)
        #expect(session.base == "notes:")
        #expect(session.transcript == "call Priya")
    }

    /// A queued message recalled with Up, a restored failed prompt, and text
    /// typed by hand all arrive the same way: as composer text this session did
    /// not write. It becomes the new base, and the caller learns it must restart
    /// the recognizer.
    @Test func anExternalWriteBecomesTheNewBase() {
        let session = DictationSession()
        session.begin(base: "", conversationID: "c1")
        session.receive(transcript: "half a sentence")
        #expect(session.rebaseIfExternal(composer: "recalled queued message"))
        #expect(session.base == "recalled queued message")
        #expect(session.composerText == "recalled queued message")
    }

    /// The re-base drops the transcript as well. Keeping it would write the old
    /// words a second time, after the text that now holds them.
    @Test func anExternalWriteDropsTheTranscriptItReplaced() {
        let session = DictationSession()
        session.begin(base: "", conversationID: "c1")
        session.receive(transcript: "half a sentence")
        _ = session.rebaseIfExternal(composer: "half a sentence and the rest")
        #expect(session.transcript == "")
        #expect(
            session.receive(transcript: "spoken after")
                == "half a sentence and the rest spoken after"
        )
    }

    /// An external write keeps the conversation the session started in: the
    /// session did not move, only the text did.
    @Test func anExternalWriteKeepsTheSessionsConversation() {
        let session = DictationSession()
        session.begin(base: "", conversationID: "c1")
        _ = session.rebaseIfExternal(composer: "typed by hand")
        #expect(session.conversationID == "c1")
    }

    /// The session records where it started, because the composer, the draft
    /// store and the voice-input flag all belong to that conversation - not to
    /// whichever conversation is selected when the session ends.
    @Test func theSessionRemembersTheConversationItStartedIn() {
        let session = DictationSession()
        session.begin(base: "", conversationID: "c1")
        session.receive(transcript: "words for the first conversation")
        #expect(session.conversationID == "c1")
    }

    @Test func endingASessionForgetsItsState() {
        let session = DictationSession()
        session.begin(base: "notes:", conversationID: "c1")
        session.receive(transcript: "call Priya")
        session.end()
        #expect(session.base == "")
        #expect(session.transcript == "")
        #expect(session.conversationID == nil)
    }
}
