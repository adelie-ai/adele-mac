import Testing
import Foundation
@testable import AdeleCore

/// Spec: both paths that put a bubble on screen — a reloaded `ChatMessage` and
/// a live `inline_note` — carry api-model's `MessageKind` presentation metadata
/// (voice#126), so the transcript badges a Spoken / SpeechDisabled turn without
/// parsing its content. The decode tolerates the field's absence, because older
/// daemons and older cores don't emit it.
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

    // The live path. A `say_this` line spoken DURING a turn is client-generated,
    // so it arrives as an `inline_note` event rather than in a reloaded
    // transcript. The kind used to be stringified into that event's text and
    // split back off here; it now travels structured, so the badge is driven by
    // metadata on the live path exactly as it already is on reload.
    @Test func liveSpokenLineBadgesWithoutParsing() throws {
        guard case .inlineNote(let text, let kind) =
            try decodeEvent(#"{"type":"inline_note","text":"hello there","kind":"spoken"}"#)
        else {
            Issue.record("expected .inlineNote"); return
        }
        #expect(kind == .spoken)
        #expect(kind.badgeLabel == "Spoken")
        // No marker survives into the bubble's text — the badge carries it.
        #expect(text == "hello there")
    }

    @Test func liveSuppressedLineBadgesWithoutParsing() throws {
        guard case .inlineNote(let text, let kind) =
            try decodeEvent(#"{"type":"inline_note","text":"hello there","kind":"speech_disabled"}"#)
        else {
            Issue.record("expected .inlineNote"); return
        }
        #expect(kind == .speechDisabled)
        #expect(kind.badgeLabel == "Speech off")
        #expect(text == "hello there")
    }

    @Test func anOrdinaryInlineNoteIsUnbadged() throws {
        guard case .inlineNote(let text, let kind) =
            try decodeEvent(#"{"type":"inline_note","text":"Reconnected.","kind":"normal"}"#)
        else {
            Issue.record("expected .inlineNote"); return
        }
        #expect(kind == .normal)
        #expect(kind.badgeLabel == nil)
        #expect(text == "Reconnected.")
    }

    // An older core sends no `kind` on the note. It must decode (not throw), and
    // its text must be left exactly as sent — including text that merely looks
    // like the retired marker, which is the string-matching this change retires.
    @Test func inlineNoteWithoutAKindIsOrdinaryAndUnparsed() throws {
        guard case .inlineNote(let text, let kind) =
            try decodeEvent(#"{"type":"inline_note","text":"Spoken: hello there"}"#)
        else {
            Issue.record("expected .inlineNote"); return
        }
        #expect(kind == .normal)
        #expect(text == "Spoken: hello there")
    }

    // Forward-compat, matching the transcript path: an unknown token renders as
    // an ordinary note rather than failing the event decode.
    @Test func inlineNoteWithAnUnknownKindIsOrdinary() throws {
        guard case .inlineNote(_, let kind) =
            try decodeEvent(#"{"type":"inline_note","text":"x","kind":"whispered"}"#)
        else {
            Issue.record("expected .inlineNote"); return
        }
        #expect(kind == .normal)
    }
}
