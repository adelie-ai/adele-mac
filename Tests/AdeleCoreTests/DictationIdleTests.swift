import Foundation
import Testing

@testable import AdeleCore

/// Spec for what a silence during dictation does: send the message, stop
/// listening, or nothing.
///
/// Silence means "the transcript stopped changing", which is what a recognizer
/// reports - it streams partial results while a person speaks and goes quiet
/// when they stop.
@Suite struct DictationIdleTests {
    private let sendAt5 = DictationIdleSettings(
        sendAfterSilence: true, sendAfter: 5, stopAfterSilence: false, stopAfter: 60
    )
    private let stopAt60 = DictationIdleSettings(
        sendAfterSilence: false, sendAfter: 5, stopAfterSilence: true, stopAfter: 60
    )
    private let both = DictationIdleSettings(
        sendAfterSilence: true, sendAfter: 5, stopAfterSilence: true, stopAfter: 60
    )

    // MARK: Send after silence

    @Test func aPauseSendsWhatWasDictated() {
        #expect(
            dictationIdleAction(silence: 5, hasTranscript: true, settings: sendAt5) == .send
        )
    }

    @Test func aShorterPauseDoesNothingYet() {
        #expect(
            dictationIdleAction(silence: 4.9, hasTranscript: true, settings: sendAt5) == .none
        )
    }

    /// Off means off, however long the silence.
    @Test func aPauseSendsNothingWhenTheSettingIsOff() {
        let off = DictationIdleSettings(
            sendAfterSilence: false, sendAfter: 5, stopAfterSilence: false, stopAfter: 60
        )
        #expect(dictationIdleAction(silence: 600, hasTranscript: true, settings: off) == .none)
    }

    /// Turning the mic on with a half-written message and pausing to think must
    /// not send that message: auto-send is for what was dictated.
    @Test func typedTextWithNoTranscriptIsNeverSent() {
        #expect(
            dictationIdleAction(silence: 30, hasTranscript: false, settings: sendAt5) == .none
        )
    }

    // MARK: Stop listening after silence

    @Test func aLongPauseStopsListening() {
        #expect(
            dictationIdleAction(silence: 60, hasTranscript: false, settings: stopAt60)
                == .stopListening
        )
    }

    /// The mic left on in an empty room is the case this exists for, so it does
    /// not depend on anything having been dictated.
    @Test func aLongPauseStopsListeningWithATranscriptToo() {
        #expect(
            dictationIdleAction(silence: 60, hasTranscript: true, settings: stopAt60)
                == .stopListening
        )
    }

    /// With stopping off, the microphone stays open however long the quiet - and
    /// with nothing dictated there is nothing for the other timer to send, so
    /// the answer is to do nothing at all.
    @Test func aLongPauseKeepsListeningWhenStoppingIsOff() {
        #expect(
            dictationIdleAction(silence: 600, hasTranscript: false, settings: sendAt5) == .none
        )
    }

    // MARK: Both together

    /// Sending wins: it is what the person asked for, and it resets the clock
    /// rather than ending the session.
    @Test func sendingWinsWhenBothAreDue() {
        #expect(dictationIdleAction(silence: 90, hasTranscript: true, settings: both) == .send)
    }

    /// With nothing dictated, the send is not due at all, so the longer timer
    /// still closes the microphone.
    @Test func theMicrophoneStillClosesWhenThereIsNothingToSend() {
        #expect(
            dictationIdleAction(silence: 90, hasTranscript: false, settings: both)
                == .stopListening
        )
    }

    /// Between the two thresholds, a dictated message is sent and the session
    /// carries on.
    @Test func aPauseBetweenTheTwoThresholdsSends() {
        #expect(dictationIdleAction(silence: 10, hasTranscript: true, settings: both) == .send)
    }

    // MARK: Settings

    /// The defaults the ticket asks for: sending is opt-in, closing the
    /// microphone is on.
    @Test func defaultsAreSendOffAndStopOn() {
        let defaults = DictationIdleSettings.standard
        #expect(!defaults.sendAfterSilence)
        #expect(defaults.sendAfter == 5)
        #expect(defaults.stopAfterSilence)
        #expect(defaults.stopAfter == 60)
    }

    /// A person stops inside a sentence to find the next word. A pause of a
    /// second or so is an ordinary one, and sending on it cuts the message in
    /// half, so the send timer waits longer than that whatever the setting says.
    @Test func aSendIntervalBelowTheFloorIsRaisedToIt() {
        let silly = DictationIdleSettings(
            sendAfterSilence: true, sendAfter: 1, stopAfterSilence: false, stopAfter: 60
        )
        #expect(DictationIdleSettings.minimumSendInterval == 2)
        #expect(silly.sendAfter == DictationIdleSettings.minimumSendInterval)
    }

    /// An interval of zero or less would fire on every tick; the floor keeps a
    /// mistyped setting from making dictation unusable.
    @Test func aStopIntervalBelowTheFloorIsRaisedToIt() {
        let silly = DictationIdleSettings(
            sendAfterSilence: false, sendAfter: 5, stopAfterSilence: true, stopAfter: -3
        )
        #expect(silly.stopAfter == DictationIdleSettings.minimumStopInterval)
    }

    /// A microphone that closes before the send is due makes auto-send
    /// unreachable, and nothing on screen says why. Sending is the action the
    /// person asked for, so the stop interval gives way to it.
    @Test func aStopIntervalShorterThanTheSendIntervalIsRaisedToIt() {
        let crossed = DictationIdleSettings(
            sendAfterSilence: true, sendAfter: 30, stopAfterSilence: true, stopAfter: 10
        )
        #expect(crossed.stopAfter == 30)
    }

    /// The clamp exists for this: with a send at 30 seconds and a stop set to
    /// 10, the pause reaches the send rather than closing the microphone first.
    @Test func aStopIntervalShorterThanTheSendStillLetsTheSendFire() {
        let crossed = DictationIdleSettings(
            sendAfterSilence: true, sendAfter: 30, stopAfterSilence: true, stopAfter: 10
        )
        #expect(dictationIdleAction(silence: 10, hasTranscript: true, settings: crossed) == .none)
        #expect(dictationIdleAction(silence: 30, hasTranscript: true, settings: crossed) == .send)
    }

    /// With sending off there is nothing for the stop interval to give way to,
    /// so a short one is honoured as set.
    @Test func aShortStopIntervalIsKeptWhenSendingIsOff() {
        let quickStop = DictationIdleSettings(
            sendAfterSilence: false, sendAfter: 30, stopAfterSilence: true, stopAfter: 10
        )
        #expect(quickStop.stopAfter == 10)
    }
}
