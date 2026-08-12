import Foundation

// What a silence during dictation means.
//
// The mic button is a toggle, so a dictation session outlives any one message.
// Two timers make that hands-free: a short silence sends what was dictated, and
// a longer one closes a microphone somebody left on. Both are off the clock of
// the transcript, not of the audio - a recognizer streams partial results while
// a person speaks and goes quiet when they stop, so "the transcript stopped
// changing" is the signal available.
//
// Not here: the timer itself, or the settings storage. The view owns the tick
// and `AppModel` owns the persistence; this is the decision they share, kept
// pure so it can be tested without a microphone.

/// The two silence timers, and how long each waits.
public struct DictationIdleSettings: Sendable, Hashable {
    /// Send the dictated message after a silence.
    public let sendAfterSilence: Bool
    /// Seconds of silence before sending.
    public let sendAfter: TimeInterval
    /// Stop listening after a longer silence.
    public let stopAfterSilence: Bool
    /// Seconds of silence before the microphone closes.
    public let stopAfter: TimeInterval

    /// The shortest interval either timer will use.
    ///
    /// An interval of zero or less would fire on every tick, sending a word at a
    /// time and making dictation unusable; a stored setting is raised to this
    /// rather than trusted.
    public static let minimumInterval: TimeInterval = 1

    /// Sending is opt-in; closing an abandoned microphone is not.
    public static let standard = DictationIdleSettings(
        sendAfterSilence: false, sendAfter: 5, stopAfterSilence: true, stopAfter: 60
    )

    public init(
        sendAfterSilence: Bool,
        sendAfter: TimeInterval,
        stopAfterSilence: Bool,
        stopAfter: TimeInterval
    ) {
        self.sendAfterSilence = sendAfterSilence
        self.sendAfter = max(sendAfter, Self.minimumInterval)
        self.stopAfterSilence = stopAfterSilence
        self.stopAfter = max(stopAfter, Self.minimumInterval)
    }
}

/// What to do about the silence so far.
public enum DictationIdleAction: Sendable, Hashable {
    /// Keep listening.
    case none
    /// Send the composer, and carry on listening.
    case send
    /// Close the microphone, keeping whatever was dictated.
    case stopListening
}

/// Decide what `silence` seconds without a new transcript should do.
///
/// Sending needs something dictated: turning the mic on with a half-written
/// message and pausing to think must not send that message. Closing the
/// microphone does not - a mic left on in an empty room is the case it exists
/// for.
///
/// Where both are due, sending wins. It is the action the person asked for, and
/// it resets the clock rather than ending the session.
public func dictationIdleAction(
    silence: TimeInterval,
    hasTranscript: Bool,
    settings: DictationIdleSettings
) -> DictationIdleAction {
    if settings.sendAfterSilence && hasTranscript && silence >= settings.sendAfter {
        return .send
    }
    if settings.stopAfterSilence && silence >= settings.stopAfter {
        return .stopListening
    }
    return .none
}
