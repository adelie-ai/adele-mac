import Testing
import Foundation
@testable import AdeleCore

/// Spec: the per-conversation personality override (#227, Phase 2) rides the
/// `SetConversationPersonality` command in the daemon's exact wire shape.
///
/// Source of truth (desktop-assistant):
///   - `api-model::Command::SetConversationPersonality { conversation_id,
///     personality: ConversationPersonalityView }` — externally-tagged
///     snake_case, so the wire is
///     `{"set_conversation_personality":{"conversation_id":"…","personality":{…}}}`.
///   - `ConversationPersonalityView = protocol::PersonalityOverride` — 7 traits,
///     each `Option<PersonalityLevel>` with
///     `#[serde(default, skip_serializing_if = "Option::is_none")]`. The field
///     names are BARE (`professionalism`, `warmth`, …) — NOT the
///     `personality_`-prefixed flat form used by the global `SetConfig`. Unset
///     traits are omitted; an all-unset override serializes to `{}`.
///   - `protocol::PersonalityLevel` is `#[serde(rename_all = "lowercase")]`, so
///     wire values are `"never" | "rarely" | "sometimes" | "often" | "always"`.
///   - Reply `CommandResult::ConversationPersonality(ConversationPersonalityView)`
///     serializes (snake_case) to `{"conversation_personality":{…}}`.
@Suite struct ConversationPersonalityTests {
    private func object(_ json: String) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try #require(value as? [String: Any])
    }

    // MARK: - setConversationPersonality builder (wire shape)

    @Test func setConversationPersonalityProducesBareTraitKeysUnderPersonality() throws {
        let dials = Personality(
            professionalism: "always",
            warmth: "often",
            directness: "often",
            enthusiasm: "sometimes",
            humor: "sometimes",
            sarcasm: "rarely",
            pretentiousness: "rarely"
        )
        let json = AdeleCommand.setConversationPersonality(
            conversationID: "conv-1", personality: dials)
        let cmd = try object(json)
        let payload = try #require(cmd["set_conversation_personality"] as? [String: Any])
        #expect(payload["conversation_id"] as? String == "conv-1")
        let personality = try #require(payload["personality"] as? [String: Any])

        // BARE trait names, not `personality_`-prefixed.
        #expect(personality["professionalism"] as? String == "always")
        #expect(personality["warmth"] as? String == "often")
        #expect(personality["directness"] as? String == "often")
        #expect(personality["enthusiasm"] as? String == "sometimes")
        #expect(personality["humor"] as? String == "sometimes")
        #expect(personality["sarcasm"] as? String == "rarely")
        #expect(personality["pretentiousness"] as? String == "rarely")

        #expect(personality["personality_warmth"] == nil)
        #expect(personality.count == 7)
    }

    @Test func setConversationPersonalityOmitsUnsetDials() throws {
        // A "no-nonsense" override: pin only humor + directness, inherit the
        // rest from the global personality (skip_serializing_if = Option::is_none).
        let dials = Personality(directness: "always", humor: "never")
        let json = AdeleCommand.setConversationPersonality(
            conversationID: "conv-42", personality: dials)
        let payload = try #require(
            (try object(json))["set_conversation_personality"] as? [String: Any])
        #expect(payload["conversation_id"] as? String == "conv-42")
        let personality = try #require(payload["personality"] as? [String: Any])

        #expect(personality["directness"] as? String == "always")
        #expect(personality["humor"] as? String == "never")
        #expect(personality["professionalism"] == nil)
        #expect(personality["warmth"] == nil)
        #expect(personality["enthusiasm"] == nil)
        #expect(personality["sarcasm"] == nil)
        #expect(personality["pretentiousness"] == nil)
        #expect(personality.count == 2)
    }

    @Test func setConversationPersonalityAllUnsetProducesEmptyPersonality() throws {
        // Clearing the override: all dials nil → `personality` is an empty object
        // (an all-`None` PersonalityOverride, which the daemon reads as cleared).
        let json = AdeleCommand.setConversationPersonality(
            conversationID: "conv-1", personality: Personality())
        let payload = try #require(
            (try object(json))["set_conversation_personality"] as? [String: Any])
        let personality = try #require(payload["personality"] as? [String: Any])
        #expect(personality.isEmpty)
        // The conversation id is still carried so the daemon knows what to clear.
        #expect(payload["conversation_id"] as? String == "conv-1")
    }

    @Test func setConversationPersonalityLevelsAreLowercase() throws {
        let dials = Personality(
            professionalism: "never",
            warmth: "rarely",
            directness: "sometimes",
            enthusiasm: "often",
            humor: "always"
        )
        let json = AdeleCommand.setConversationPersonality(
            conversationID: "c", personality: dials)
        let personality = try #require(
            ((try object(json))["set_conversation_personality"] as? [String: Any])?["personality"]
                as? [String: Any])
        #expect(personality["professionalism"] as? String == "never")
        #expect(personality["warmth"] as? String == "rarely")
        #expect(personality["directness"] as? String == "sometimes")
        #expect(personality["enthusiasm"] as? String == "often")
        #expect(personality["humor"] as? String == "always")
    }

    // MARK: - ConversationPersonality reply decoding

    @Test func conversationPersonalityReplyDecodesEchoedOverride() throws {
        // The daemon echoes the stored override:
        // CommandResult::ConversationPersonality(view) → {"conversation_personality":{…}}.
        let json = """
        {"type":"command_result","request_id":"r","ok":true,"result":{
          "conversation_personality":{"humor":"never","directness":"always"}
        }}
        """
        let env = try JSONDecoder().decode(
            CommandResultEnvelope<ConversationPersonalityResultPayload>.self,
            from: Data(json.utf8))
        let p = try #require(env.result?.conversationPersonality)
        #expect(p.humor == "never")
        #expect(p.directness == "always")
        // Unset traits are absent from the echo and decode to nil.
        #expect(p.warmth == nil)
        #expect(p.professionalism == nil)
    }

    @Test func conversationPersonalityReplyDecodesClearedOverride() throws {
        // An all-`None` echo (override cleared): empty personality object.
        let json = """
        {"type":"command_result","request_id":"r","ok":true,"result":{"conversation_personality":{}}}
        """
        let env = try JSONDecoder().decode(
            CommandResultEnvelope<ConversationPersonalityResultPayload>.self,
            from: Data(json.utf8))
        let p = try #require(env.result?.conversationPersonality)
        #expect(p == Personality())
    }
}
