import Testing
import Foundation
@testable import AdeleCore

/// Spec: `ChatMessage` carries api-model's `MessageKind` presentation metadata
/// (voice#126) so the transcript can badge a Spoken / SpeechDisabled turn without
/// parsing its content — and the decode tolerates the field's absence, because
/// older daemons (and today's FFI `ChatMessageDto`) don't emit it.
@Suite struct MessageKindTests {
    private func decodeMessage(_ json: String) throws -> ChatMessage {
        try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
    }

    private func decodeEvent(_ json: String) throws -> ViewEvent {
        try JSONDecoder().decode(ViewEvent.self, from: Data(json.utf8))
    }

    // The case the issue calls out explicitly: a pre-MessageKind daemon/core
    // sends no `kind` at all, and the message must still decode as ordinary.
    @Test func missingKindDecodesAsNormal() throws {
        let message = try decodeMessage(#"{"id":"m1","role":"user","content":"hi"}"#)
        #expect(message.kind == .normal)
        #expect(message.content == "hi")
    }

    @Test func explicitNormalDecodes() throws {
        #expect(try decodeMessage(#"{"id":"m1","role":"user","content":"hi","kind":"Normal"}"#).kind == .normal)
        #expect(try decodeMessage(#"{"id":"m1","role":"user","content":"hi","kind":"normal"}"#).kind == .normal)
    }

    // Serde may spell the variant PascalCase (its default) or snake_case (the
    // rename the ViewEvent tags use), so accept both rather than guessing.
    @Test func spokenDecodesFromEitherWireSpelling() throws {
        #expect(try decodeMessage(#"{"id":"m","role":"assistant","content":"c","kind":"Spoken"}"#).kind == .spoken)
        #expect(try decodeMessage(#"{"id":"m","role":"assistant","content":"c","kind":"spoken"}"#).kind == .spoken)
    }

    @Test func speechDisabledDecodesFromEitherWireSpelling() throws {
        #expect(
            try decodeMessage(#"{"id":"m","role":"assistant","content":"c","kind":"SpeechDisabled"}"#).kind
                == .speechDisabled
        )
        #expect(
            try decodeMessage(#"{"id":"m","role":"assistant","content":"c","kind":"speech_disabled"}"#).kind
                == .speechDisabled
        )
    }

    // Forward-compat: a kind this build doesn't know renders as an ordinary
    // message rather than failing the whole transcript decode.
    @Test func unknownKindFallsBackToNormal() throws {
        #expect(try decodeMessage(#"{"id":"m","role":"assistant","content":"c","kind":"Whispered"}"#).kind == .normal)
        #expect(try decodeMessage(#"{"id":"m","role":"assistant","content":"c","kind":null}"#).kind == .normal)
        #expect(try decodeMessage(#"{"id":"m","role":"assistant","content":"c","kind":7}"#).kind == .normal)
    }

    @Test func loadConversationCarriesKindPerMessage() throws {
        let json = """
        {"type":"load_conversation","detail":{"id":"c1","title":"T","messages":[\
        {"id":"m1","role":"user","content":"hi"},\
        {"id":"m2","role":"assistant","content":"spoken line","kind":"Spoken"},\
        {"id":"m3","role":"assistant","content":"muted line","kind":"SpeechDisabled"}]}}
        """
        guard case .loadConversation(let detail) = try decodeEvent(json) else {
            Issue.record("expected .loadConversation"); return
        }
        #expect(detail.messages.map(\.kind) == [.normal, .spoken, .speechDisabled])
    }

    @Test func onlyTaggedKindsCarryABadge() {
        #expect(MessageKind.normal.badgeLabel == nil)
        #expect(MessageKind.spoken.badgeLabel == "Spoken")
        #expect(MessageKind.speechDisabled.badgeLabel == "Speech off")
        #expect(MessageKind.normal.accessibilityDescription == nil)
        #expect(MessageKind.spoken.accessibilityDescription != nil)
        #expect(MessageKind.speechDisabled.accessibilityDescription != nil)
    }

    // Interim bridge: today's FFI stringifies the note's kind into the
    // `inline_note` text (client-ui-ffi view_event.rs). Recover the structured
    // kind so the badge — not a text marker — carries it.
    @Test func inlineNoteMarkersRecoverTheKind() {
        let spoken = MessageKind.fromInlineNote("Spoken: hello there")
        #expect(spoken.kind == .spoken)
        #expect(spoken.content == "hello there")

        let muted = MessageKind.fromInlineNote("(speech mode disabled) hello there")
        #expect(muted.kind == .speechDisabled)
        #expect(muted.content == "hello there")
    }

    @Test func inlineNoteWithoutAMarkerIsLeftAlone() {
        let plain = MessageKind.fromInlineNote("Reconnected to the daemon.")
        #expect(plain.kind == .normal)
        #expect(plain.content == "Reconnected to the daemon.")

        // A near-miss must not be mangled: only the exact marker prefix counts.
        let nearMiss = MessageKind.fromInlineNote("Spoken words are cheap")
        #expect(nearMiss.kind == .normal)
        #expect(nearMiss.content == "Spoken words are cheap")
    }
}
