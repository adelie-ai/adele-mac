import Foundation

/// Builder for the per-conversation personality override (issue #227, Phase 2).
///
/// Unlike the GLOBAL personality — which is written via `SetConfig` with FLAT,
/// snake_case `personality_<trait>` change keys (see `Commands+Personality.swift`)
/// — the per-conversation override rides its own command whose payload is the
/// daemon's `PersonalityOverride` verbatim. The wire shapes come from the
/// daemon's source of truth (desktop-assistant):
///
///   - **Command** (`api-model::Command`, externally-tagged snake_case):
///     `SetConversationPersonality { conversation_id: String,
///     personality: ConversationPersonalityView }`, so the wire is
///     `{"set_conversation_personality":{"conversation_id":"<id>",
///       "personality":{<trait>:"<level>", …}}}`.
///
///   - **`ConversationPersonalityView = protocol::PersonalityOverride`**: 7
///     traits, each `Option<PersonalityLevel>` annotated
///     `#[serde(default, skip_serializing_if = "Option::is_none")]`. The trait
///     keys are BARE (`professionalism`, `warmth`, `directness`, `enthusiasm`,
///     `humor`, `sarcasm`, `pretentiousness`) — NOT `personality_`-prefixed. A
///     `Some` trait pins it for the conversation; an omitted trait falls back to
///     the global personality. An all-unset override serializes to `{}`, which
///     the daemon reads as "clear the override".
///
///   - **Levels** (`protocol::PersonalityLevel`, `rename_all = "lowercase"`):
///     `"never" | "rarely" | "sometimes" | "often" | "always"`.
///
/// Confidence in this shape is HIGH — read directly off `PersonalityOverride`'s
/// field definitions in `crates/protocol/src/lib.rs` and the
/// `set_conversation_personality_command_round_trips` test in
/// `crates/api-model/src/lib.rs`.
extension AdeleCommand {
    /// Build the `SetConversationPersonality` wire JSON. `personality` is a
    /// `Personality` used here as a partial override: only its non-nil dials are
    /// emitted, each as a BARE trait key inside `personality`. An all-nil
    /// `Personality` yields `"personality":{}` (clears the override). `nil` dials
    /// are omitted by Swift's synthesized `Encodable` (`encodeIfPresent`).
    public static func setConversationPersonality(
        conversationID: String,
        personality: Personality
    ) -> String {
        // Bare (unprefixed) trait keys — the `PersonalityOverride` field names.
        struct Override: Encodable {
            let professionalism: String?
            let warmth: String?
            let directness: String?
            let enthusiasm: String?
            let humor: String?
            let sarcasm: String?
            let pretentiousness: String?
        }
        struct Payload: Encodable {
            let conversation_id: String
            let personality: Override
        }
        struct Cmd: Encodable { let set_conversation_personality: Payload }
        return encode(Cmd(set_conversation_personality: Payload(
            conversation_id: conversationID,
            personality: Override(
                professionalism: personality.professionalism,
                warmth: personality.warmth,
                directness: personality.directness,
                enthusiasm: personality.enthusiasm,
                humor: personality.humor,
                sarcasm: personality.sarcasm,
                pretentiousness: personality.pretentiousness
            )
        )))
    }
}
