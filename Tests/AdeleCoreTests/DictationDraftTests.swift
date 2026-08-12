import Testing

@testable import AdeleCore

/// Spec for the composer text a dictation transcript produces.
///
/// `SFSpeechRecognitionTask` reports the transcript of the whole task, and it
/// revises words it has already reported as later context arrives. So a
/// transcript replaces the previous transcript and is never appended to it -
/// what it must not replace is whatever the person typed before dictating.
@Suite struct DictationDraftTests {
    @Test func aTranscriptIsTheDraftWhenNothingWasTyped() {
        #expect(dictationDraft(base: "", transcript: "hello world") == "hello world")
    }

    /// Typed text survives: dictation adds to the composer rather than taking it
    /// over.
    @Test func typedTextKeepsItsPlaceBeforeTheTranscript() {
        #expect(
            dictationDraft(base: "meeting notes:", transcript: "call Priya")
                == "meeting notes: call Priya"
        )
    }

    /// The recognizer rewrites earlier words as it hears more. Each transcript
    /// replaces the last one whole, so a revision must not leave both versions.
    @Test func aRevisedTranscriptReplacesTheEarlierOne() {
        let base = "notes:"
        let first = dictationDraft(base: base, transcript: "call pre")
        let revised = dictationDraft(base: base, transcript: "call Priya")
        #expect(first == "notes: call pre")
        #expect(revised == "notes: call Priya")
        #expect(!revised.contains("pre "))
    }

    /// One separator, whoever supplied it: a base that already ends in a space
    /// does not get a second one.
    @Test func theJoinNeverDoublesTheSeparator() {
        #expect(dictationDraft(base: "notes: ", transcript: "hello") == "notes: hello")
        #expect(dictationDraft(base: "notes:\n", transcript: "hello") == "notes:\nhello")
    }

    /// An empty transcript leaves the typed text exactly as it was - the first
    /// callback of a session must not append a stray separator.
    @Test func anEmptyTranscriptLeavesTheBaseUntouched() {
        #expect(dictationDraft(base: "meeting notes:", transcript: "") == "meeting notes:")
        #expect(dictationDraft(base: "", transcript: "") == "")
    }

    /// Sending consumes the composer, so the next transcript starts from
    /// nothing - the reset that follows a send has no typed text to preserve.
    @Test func theBaseAfterASendIsEmpty() {
        #expect(dictationBaseAfterSend() == "")
    }
}
