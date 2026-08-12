import Foundation
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
    /// A fixed origin on the same clock the session measures with. Every case
    /// builds its instants from this one, so no case waits for real time.
    private let t0 = SuspendingClock.now

    /// Dictation adds to the composer rather than taking it over.
    @Test func aSessionStartsFromWhatWasAlreadyTyped() {
        let session = DictationSession()
        session.begin(base: "meeting notes:", conversationID: "c1", at: t0)
        #expect(session.base == "meeting notes:")
        #expect(session.transcript == "")
        #expect(session.composerText == "meeting notes:")
    }

    /// The recognizer reports the whole task each time and revises words it
    /// already reported, so a transcript replaces the one before it.
    @Test func eachTranscriptReplacesTheOneBefore() {
        let session = DictationSession()
        session.begin(base: "notes:", conversationID: "c1", at: t0)
        #expect(session.receive(transcript: "call pre", at: t0) == "notes: call pre")
        #expect(session.receive(transcript: "call Priya", at: t0) == "notes: call Priya")
        #expect(session.transcript == "call Priya")
    }

    /// A send consumes the composer, so the session keeps neither the typed base
    /// nor the words that went with it.
    @Test func aSendConsumesTheBaseAndTheTranscript() {
        let session = DictationSession()
        session.begin(base: "notes:", conversationID: "c1", at: t0)
        session.receive(transcript: "call Priya", at: t0)
        session.consumeOnSend(at: t0)
        #expect(session.base == "")
        #expect(session.transcript == "")
        #expect(session.composerText == "")
    }

    /// The defect this exists to prevent (#42): after a send, the next
    /// transcript must not put the sent words back in the cleared composer.
    @Test func theTranscriptAfterASendCarriesNoSentWords() {
        let session = DictationSession()
        session.begin(base: "", conversationID: "c1", at: t0)
        session.receive(transcript: "first message", at: t0)
        session.consumeOnSend(at: t0)
        #expect(session.receive(transcript: "second message", at: t0) == "second message")
    }

    /// The composer text the session itself produced is not an external write,
    /// so a session is never re-based on its own output.
    @Test func theTextTheSessionWroteIsNotExternal() {
        let session = DictationSession()
        session.begin(base: "notes:", conversationID: "c1", at: t0)
        let written = session.receive(transcript: "call Priya", at: t0)
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
        session.begin(base: "", conversationID: "c1", at: t0)
        session.receive(transcript: "half a sentence", at: t0)
        #expect(session.rebaseIfExternal(composer: "recalled queued message"))
        #expect(session.base == "recalled queued message")
        #expect(session.composerText == "recalled queued message")
    }

    /// The re-base drops the transcript as well. Keeping it would write the old
    /// words a second time, after the text that now holds them.
    @Test func anExternalWriteDropsTheTranscriptItReplaced() {
        let session = DictationSession()
        session.begin(base: "", conversationID: "c1", at: t0)
        session.receive(transcript: "half a sentence", at: t0)
        _ = session.rebaseIfExternal(composer: "half a sentence and the rest")
        #expect(session.transcript == "")
        #expect(
            session.receive(transcript: "spoken after", at: t0)
                == "half a sentence and the rest spoken after"
        )
    }

    /// An external write keeps the conversation the session started in: the
    /// session did not move, only the text did.
    @Test func anExternalWriteKeepsTheSessionsConversation() {
        let session = DictationSession()
        session.begin(base: "", conversationID: "c1", at: t0)
        _ = session.rebaseIfExternal(composer: "typed by hand")
        #expect(session.conversationID == "c1")
    }

    /// The session records where it started, because the composer, the draft
    /// store and the voice-input flag all belong to that conversation - not to
    /// whichever conversation is selected when the session ends.
    @Test func theSessionRemembersTheConversationItStartedIn() {
        let session = DictationSession()
        session.begin(base: "", conversationID: "c1", at: t0)
        session.receive(transcript: "words for the first conversation", at: t0)
        #expect(session.conversationID == "c1")
    }

    @Test func endingASessionForgetsItsState() {
        let session = DictationSession()
        session.begin(base: "notes:", conversationID: "c1", at: t0)
        session.receive(transcript: "call Priya", at: t0)
        session.end()
        #expect(session.base == "")
        #expect(session.transcript == "")
        #expect(session.conversationID == nil)
        #expect(!session.hasTranscript)
    }

    // MARK: A task rollover

    /// A recognition task stops on its own after about a minute of audio. The
    /// person did not ask for that, so the session continues: the words of the
    /// task that ended move into the base, and the composer reads the same as it
    /// did the moment before.
    @Test func aTaskRolloverKeepsTheComposerTextItAlreadyProduced() {
        let session = DictationSession()
        session.begin(base: "notes:", conversationID: "c1", at: t0)
        session.receive(transcript: "the first minute of words", at: t0)
        #expect(session.commitOnTaskRollover(finalTranscript: nil) == "notes: the first minute of words")
        #expect(session.base == "notes: the first minute of words")
        #expect(session.transcript == "")
    }

    /// The task delivers a last transcript as it stops, and it revises words it
    /// reported before. That revision is what the session banks.
    @Test func aTaskRolloverBanksTheFinalTranscriptRatherThanTheLastPartial() {
        let session = DictationSession()
        session.begin(base: "notes:", conversationID: "c1", at: t0)
        session.receive(transcript: "call pre", at: t0)
        #expect(session.commitOnTaskRollover(finalTranscript: "call Priya") == "notes: call Priya")
        #expect(session.base == "notes: call Priya")
        #expect(session.transcript == "")
    }

    /// The final transcript is a revision of words already spoken, not new
    /// speech, so it does not restart the silence clock either. A person who
    /// stopped talking at ten seconds must have the microphone close on time,
    /// not a minute later when the task reaches its own limit.
    @Test func aFinalTranscriptAtATaskRolloverDoesNotRestartTheSilenceClock() {
        let session = DictationSession()
        session.begin(base: "", conversationID: "c1", at: t0)
        session.receive(transcript: "call pre", at: t0.advanced(by: .seconds(10)))
        _ = session.commitOnTaskRollover(finalTranscript: "call Priya")
        #expect(session.silence(now: t0.advanced(by: .seconds(70))) == 60)
    }

    /// A task that heard nothing banks nothing.
    @Test func anEmptyFinalTranscriptAfterNoSpeechBanksNothing() {
        let session = DictationSession()
        session.begin(base: "meeting notes:", conversationID: "c1", at: t0)
        #expect(session.commitOnTaskRollover(finalTranscript: "") == "meeting notes:")
        #expect(!session.hasTranscript)
    }

    /// An empty final transcript is no revision at all, so it leaves the words
    /// the task already reported alone. Taking it as a revision would delete
    /// what the person is looking at, a minute into dictating.
    @Test func anEmptyFinalTranscriptDoesNotEraseTheWordsAlreadyHeard() {
        let session = DictationSession()
        session.begin(base: "notes:", conversationID: "c1", at: t0)
        session.receive(transcript: "call Priya", at: t0)
        #expect(session.commitOnTaskRollover(finalTranscript: "   ") == "notes: call Priya")
        #expect(session.hasTranscript)
    }

    /// The next task starts an empty transcript, so what the last one heard has
    /// to be in the base. Without that, the first partial of the new task would
    /// replace the whole minute before it.
    @Test func aTaskRolloverBanksTheWordsSoTheNextTaskAddsToThem() {
        let session = DictationSession()
        session.begin(base: "", conversationID: "c1", at: t0)
        session.receive(transcript: "the first minute of words", at: t0)
        _ = session.commitOnTaskRollover(finalTranscript: nil)
        #expect(
            session.receive(transcript: "and the next", at: t0)
                == "the first minute of words and the next"
        )
    }

    /// A rollover is not speech, so it does not count as a reason to keep the
    /// microphone open. The clock keeps measuring from the last words heard.
    @Test func aTaskRolloverDoesNotRestartTheSilenceClock() {
        let session = DictationSession()
        session.begin(base: "", conversationID: "c1", at: t0)
        session.receive(transcript: "book the flight", at: t0.advanced(by: .seconds(2)))
        _ = session.commitOnTaskRollover(finalTranscript: nil)
        #expect(session.silence(now: t0.advanced(by: .seconds(62))) == 60)
    }

    /// A silence that sends asks whether anything was dictated. Words banked by
    /// a rollover were dictated, so a pause after one still sends them.
    @Test func wordsBankedByATaskRolloverStillCountAsATranscript() {
        let session = DictationSession()
        session.begin(base: "", conversationID: "c1", at: t0)
        session.receive(transcript: "book the flight", at: t0)
        _ = session.commitOnTaskRollover(finalTranscript: nil)
        #expect(session.hasTranscript)
    }

    /// A rollover with nothing heard banks nothing, so typed text alone is still
    /// never sent by a pause.
    @Test func aTaskRolloverWithNothingHeardBanksNothing() {
        let session = DictationSession()
        session.begin(base: "meeting notes:", conversationID: "c1", at: t0)
        _ = session.commitOnTaskRollover(finalTranscript: nil)
        #expect(!session.hasTranscript)
        #expect(session.composerText == "meeting notes:")
    }

    /// The send takes the banked words with it, so the pause after it does not
    /// send a second time.
    @Test func aSendAfterATaskRolloverTakesTheBankedWordsWithIt() {
        let session = DictationSession()
        session.begin(base: "", conversationID: "c1", at: t0)
        session.receive(transcript: "book the flight", at: t0)
        _ = session.commitOnTaskRollover(finalTranscript: nil)
        session.consumeOnSend(at: t0)
        #expect(session.composerText == "")
        #expect(!session.hasTranscript)
    }

    /// Typing over a rollover replaces what was banked, the same as it replaces
    /// a live transcript.
    @Test func anExternalWriteDropsTheWordsATaskRolloverBanked() {
        let session = DictationSession()
        session.begin(base: "", conversationID: "c1", at: t0)
        session.receive(transcript: "book the flight", at: t0)
        _ = session.commitOnTaskRollover(finalTranscript: nil)
        #expect(session.rebaseIfExternal(composer: "typed instead"))
        #expect(!session.hasTranscript)
        #expect(session.composerText == "typed instead")
    }

    // MARK: The silence clock

    /// The clock reads in seconds, because that is the unit the two intervals
    /// are set in.
    @Test func silenceIsTheSecondsSinceTheTranscriptLastChanged() {
        let session = DictationSession()
        session.begin(base: "", conversationID: "c1", at: t0)
        session.receive(transcript: "book the flight", at: t0.advanced(by: .seconds(2)))
        #expect(session.silence(now: t0.advanced(by: .milliseconds(3500))) == 1.5)
    }

    /// The recognizer can report the same words again. Counting that as speech
    /// would keep a silence from ever completing, so the clock does not move.
    @Test func aRepeatedTranscriptDoesNotRestartTheSilenceClock() {
        let session = DictationSession()
        session.begin(base: "", conversationID: "c1", at: t0)
        session.receive(transcript: "book the flight", at: t0.advanced(by: .seconds(1)))
        session.receive(transcript: "book the flight", at: t0.advanced(by: .seconds(9)))
        #expect(session.silence(now: t0.advanced(by: .seconds(11))) == 10)
    }

    /// New words are speech, so the clock starts again from them.
    @Test func aChangedTranscriptRestartsTheSilenceClock() {
        let session = DictationSession()
        session.begin(base: "", conversationID: "c1", at: t0)
        session.receive(transcript: "book", at: t0.advanced(by: .seconds(1)))
        session.receive(transcript: "book the flight", at: t0.advanced(by: .seconds(9)))
        #expect(session.silence(now: t0.advanced(by: .seconds(11))) == 2)
    }

    /// Sending resets the clock, so a person can dictate several messages and
    /// the longer timer only fires after a real silence.
    @Test func sendingRestartsTheSilenceClock() {
        let session = DictationSession()
        session.begin(base: "", conversationID: "c1", at: t0)
        session.receive(transcript: "book the flight", at: t0.advanced(by: .seconds(1)))
        session.consumeOnSend(at: t0.advanced(by: .seconds(4)))
        #expect(session.silence(now: t0.advanced(by: .seconds(5))) == 1)
    }

    /// Typing is not speech. The longer timer exists to close a microphone
    /// nobody is speaking into, and ten minutes of typing must not hold it open
    /// (#47).
    @Test func anExternalWriteDoesNotRestartTheSilenceClock() {
        let session = DictationSession()
        session.begin(base: "", conversationID: "c1", at: t0)
        session.receive(transcript: "half a sentence", at: t0.advanced(by: .seconds(1)))
        #expect(session.rebaseIfExternal(composer: "typed by hand"))
        #expect(session.silence(now: t0.advanced(by: .seconds(61))) == 60)
    }

    /// A changed setting must not fire against a silence that was already
    /// banked: turning "send after a pause" on after twenty seconds of quiet
    /// must not send at once. The view restarts the clock, and the measurement
    /// begins from there.
    @Test func restartingTheClockDiscardsTheSilenceMeasuredSoFar() {
        let session = DictationSession()
        session.begin(base: "", conversationID: "c1", at: t0)
        session.receive(transcript: "book the flight", at: t0.advanced(by: .seconds(1)))
        session.restartSilenceClock(at: t0.advanced(by: .seconds(21)))
        #expect(session.silence(now: t0.advanced(by: .seconds(22))) == 1)
    }

    /// Restarting the clock changes nothing else: the words stay, and a pause
    /// after the new measurement still sends them.
    @Test func restartingTheClockKeepsTheTranscript() {
        let session = DictationSession()
        session.begin(base: "notes:", conversationID: "c1", at: t0)
        session.receive(transcript: "book the flight", at: t0)
        session.restartSilenceClock(at: t0.advanced(by: .seconds(21)))
        #expect(session.transcript == "book the flight")
        #expect(session.base == "notes:")
        #expect(session.composerText == "notes: book the flight")
        #expect(session.hasTranscript)
    }

    /// A silence that sends asks this, so typed text alone is never sent by a
    /// pause - and neither is a transcript of nothing but spaces.
    @Test func onlyRealDictatedWordsCountAsATranscript() {
        let session = DictationSession()
        session.begin(base: "meeting notes:", conversationID: "c1", at: t0)
        #expect(!session.hasTranscript)
        session.receive(transcript: "   ", at: t0)
        #expect(!session.hasTranscript)
        session.receive(transcript: "call Priya", at: t0)
        #expect(session.hasTranscript)
    }
}
