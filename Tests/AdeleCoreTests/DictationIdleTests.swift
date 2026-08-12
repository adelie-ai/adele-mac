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
    @Test func aLongPauseStopsListeningWithATranscriptTooo() {
        #expect(
            dictationIdleAction(silence: 60, hasTranscript: true, settings: stopAt60)
                == .stopListening
        )
    }

    @Test func aLongPauseKeepsListeningWhenTheSettingIsOff() {
        #expect(dictationIdleAction(silence: 600, hasTranscript: true, settings: sendAt5) == .send)
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

    /// An interval of zero or less would fire on every tick, sending a word at a
    /// time; the floor keeps a mistyped setting from making dictation unusable.
    @Test func anIntervalBelowTheFloorIsRaisedToIt() {
        let silly = DictationIdleSettings(
            sendAfterSilence: true, sendAfter: 0, stopAfterSilence: true, stopAfter: -3
        )
        #expect(silly.sendAfter >= DictationIdleSettings.minimumInterval)
        #expect(silly.stopAfter >= DictationIdleSettings.minimumInterval)
    }
}
