import Foundation

/// Personality dial builders for the transport-level config API.
///
/// Personality is read via the existing `getConfig` unit command and written via
/// `SetConfig { changes: ConfigChanges }`. The exact wire shapes come from the
/// daemon's source of truth (desktop-assistant `crates/api-model/src/lib.rs` and
/// `crates/protocol/src/lib.rs`):
///
///   - **Read** (`Config`): the 7 trait levels live in a NESTED struct under
///     `config.personality` — `{"config":{…,"personality":{"warmth":"often",…}}}`.
///     (Decoding is handled in `Management+Personality.swift`.)
///
///   - **Write** (`ConfigChanges`): a personality change is expressed as FLAT,
///     snake_case keys `personality_<trait>` placed DIRECTLY in `changes` — NOT
///     as a nested `personality` object. Each key is `Option<PersonalityLevel>`
///     and is omitted from the wire when unset (`skip_serializing_if =
///     "Option::is_none"`). So setting only warmth+humor emits exactly:
///     `{"set_config":{"changes":{"personality_warmth":"often",
///       "personality_humor":"never"}}}`.
///
///   - **Levels** (`PersonalityLevel`, `#[serde(rename_all = "lowercase")]`):
///     the string values are `"never" | "rarely" | "sometimes" | "often" |
///     "always"`.
///
/// Confidence in this shape is HIGH — it is read directly off the `ConfigChanges`
/// struct definition, whose `personality_*` fields are flat siblings of the
/// embeddings/persistence change fields (there is no nested personality change
/// type in the daemon).
extension AdeleCommand {
    /// Build the `SetConfig` wire JSON that updates ONLY the personality dials.
    ///
    /// `dials` is a `Personality` where each trait is an optional snake_case
    /// level string (or `nil` to leave that dial unchanged). Only the non-nil
    /// dials are emitted, each as a flat `personality_<trait>` key inside
    /// `changes` — matching `ConfigChanges`'s partial-update semantics. `nil`
    /// dials are omitted (Swift's synthesized `Encodable` uses `encodeIfPresent`
    /// for optionals), so an all-nil `Personality` yields `"changes":{}`.
    public static func setPersonality(_ dials: Personality) -> String {
        // Flat change keys; nil optionals are omitted by the synthesized encoder.
        struct Changes: Encodable {
            let personality_professionalism: String?
            let personality_warmth: String?
            let personality_directness: String?
            let personality_enthusiasm: String?
            let personality_humor: String?
            let personality_sarcasm: String?
            let personality_pretentiousness: String?
        }
        struct Payload: Encodable { let changes: Changes }
        struct Cmd: Encodable { let set_config: Payload }
        return encode(Cmd(set_config: Payload(changes: Changes(
            personality_professionalism: dials.professionalism,
            personality_warmth: dials.warmth,
            personality_directness: dials.directness,
            personality_enthusiasm: dials.enthusiasm,
            personality_humor: dials.humor,
            personality_sarcasm: dials.sarcasm,
            personality_pretentiousness: dials.pretentiousness
        ))))
    }
}
