import Testing

@testable import AdeleCore

/// Spec for the one rule the composer applies before a send: what text, if any,
/// a draft sends.
///
/// The answer is also the answer to "did a send happen", which the caller needs.
/// A dictation session resets on send - it drops the words the recognizer still
/// holds - so a reset after a refused send destroys a sentence that was never
/// delivered.
@Suite struct ComposerSendTests {
    @Test func aTypedDraftIsTheTextToSend() {
        #expect(promptToSend(draft: "call Priya at four") == "call Priya at four")
    }

    /// Leading and trailing whitespace is not part of the message.
    @Test func theTextToSendIsTrimmed() {
        #expect(promptToSend(draft: "  call Priya \n") == "call Priya")
    }

    @Test func anEmptyDraftSendsNothing() {
        #expect(promptToSend(draft: "") == nil)
    }

    /// Whitespace alone holds no message. Return pressed on it must report that
    /// nothing was sent, so the caller leaves the dictation session running.
    @Test func aWhitespaceOnlyDraftSendsNothing() {
        #expect(promptToSend(draft: "   \n\t ") == nil)
    }

    /// Inner whitespace and newlines belong to the message.
    @Test func aMultiLineDraftKeepsItsLineBreaks() {
        #expect(promptToSend(draft: "first line\nsecond line") == "first line\nsecond line")
    }
}
