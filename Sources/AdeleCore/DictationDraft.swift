import Foundation

// How a speech transcript becomes composer text.
//
// A speech recognition task reports the transcript of the whole task, not the
// words since the last callback, and it revises words it already reported as
// later context arrives. Two consequences shape everything here: a transcript
// **replaces** the previous transcript rather than being appended to it, and the
// only thing it must not replace is what the person typed before dictating.
//
// Not here: driving the recognizer, or deciding when a session resets. That is
// `Dictation` and the composer in the app target.

/// The composer text for `transcript`, keeping `base` - whatever was typed
/// before this dictation session started - in front of it.
///
/// Each call takes the transcript whole, so a revised transcript replaces the
/// one before it rather than leaving both. Diffing successive transcripts to
/// find "the new words" is what this exists to avoid: the recognizer rewrites
/// its own earlier output, so a diff duplicates and mangles text.
public func dictationDraft(base: String, transcript: String) -> String {
    guard !transcript.isEmpty else { return base }
    guard !base.isEmpty else { return transcript }
    // One separator, whoever supplied it.
    let separator = base.last?.isWhitespace == true ? "" : " "
    return base + separator + transcript
}

/// The base a dictation session resets to after a send.
///
/// Sending consumes the composer, so the next transcript starts from nothing.
/// Named rather than written as `""` at the call site, because it is the answer
/// to "what happened to the words that were already sent", and the wrong answer
/// there is the defect this exists to prevent.
public func dictationBaseAfterSend() -> String { "" }
