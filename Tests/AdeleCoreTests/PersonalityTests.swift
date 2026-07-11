import Testing
import Foundation
@testable import AdeleCore

/// Spec: the personality dials round-trip through the transport-level config
/// API (`GetConfig` / `SetConfig`) in the daemon's exact wire shapes.
///
/// Source of truth (desktop-assistant):
///   - `api-model::Config { personality: Personality }` — GetConfig reply nests
///     the 7 trait levels under `config.personality`.
///   - `api-model::ConfigChanges` — SetConfig carries the personality change as
///     FLAT keys `personality_<trait>` (e.g. `personality_warmth`) directly in
///     `changes`, each `Option<PersonalityLevel>` skipped when `None`. There is
///     NO nested `personality` object in a change.
///   - `protocol::PersonalityLevel` is `#[serde(rename_all = "lowercase")]`, so
///     wire values are `"never" | "rarely" | "sometimes" | "often" | "always"`.
@Suite struct PersonalityTests {
    private func object(_ json: String) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try #require(value as? [String: Any])
    }

    // MARK: - setPersonality builder (SetConfig wire shape)

    @Test func setPersonalityProducesFlatSnakeCaseChangeKeys() throws {
        let dials = Personality(
            professionalism: "always",
            warmth: "often",
            directness: "often",
            enthusiasm: "sometimes",
            humor: "sometimes",
            sarcasm: "rarely",
            pretentiousness: "rarely"
        )
        let json = AdeleCommand.setPersonality(dials)
        let cmd = try object(json)
        let setConfig = try #require(cmd["set_config"] as? [String: Any])
        let changes = try #require(setConfig["changes"] as? [String: Any])

        #expect(changes["personality_professionalism"] as? String == "always")
        #expect(changes["personality_warmth"] as? String == "often")
        #expect(changes["personality_directness"] as? String == "often")
        #expect(changes["personality_enthusiasm"] as? String == "sometimes")
        #expect(changes["personality_humor"] as? String == "sometimes")
        #expect(changes["personality_sarcasm"] as? String == "rarely")
        #expect(changes["personality_pretentiousness"] as? String == "rarely")

        // Flat, not nested: there must be no `personality` sub-object.
        #expect(changes["personality"] == nil)
        #expect(changes.count == 7)
    }

    @Test func setPersonalityOmitsUnsetDials() throws {
        // Only two dials set; the rest are nil and must not appear on the wire
        // (mirrors ConfigChanges' skip_serializing_if = Option::is_none).
        let dials = Personality(warmth: "always", humor: "never")
        let json = AdeleCommand.setPersonality(dials)
        let setConfig = try #require((try object(json))["set_config"] as? [String: Any])
        let changes = try #require(setConfig["changes"] as? [String: Any])

        #expect(changes["personality_warmth"] as? String == "always")
        #expect(changes["personality_humor"] as? String == "never")
        #expect(changes["personality_professionalism"] == nil)
        #expect(changes["personality_directness"] == nil)
        #expect(changes["personality_enthusiasm"] == nil)
        #expect(changes["personality_sarcasm"] == nil)
        #expect(changes["personality_pretentiousness"] == nil)
        #expect(changes.count == 2)
    }

    @Test func setPersonalityAllUnsetProducesEmptyChanges() throws {
        let json = AdeleCommand.setPersonality(Personality())
        let setConfig = try #require((try object(json))["set_config"] as? [String: Any])
        let changes = try #require(setConfig["changes"] as? [String: Any])
        #expect(changes.isEmpty)
    }

    // MARK: - GetConfig reply decoding

    @Test func getConfigReplyDecodesPersonality() throws {
        // Full daemon reply: personality nested under config.personality, with
        // the other Config sections present (and ignored by our loose decode).
        let json = """
        {"type":"command_result","request_id":"r","ok":true,"result":{"config":{
          "embeddings":{"connector":"ollama","model":"nomic","base_url":"","has_api_key":false,"available":true,"is_default":true},
          "persistence":{"enabled":false,"remote_url":"","remote_name":"","push_on_update":false},
          "personality":{"professionalism":"always","warmth":"often","directness":"often","enthusiasm":"sometimes","humor":"sometimes","sarcasm":"rarely","pretentiousness":"rarely"}
        }}}
        """
        let env = try JSONDecoder().decode(
            CommandResultEnvelope<ConfigResultPayload>.self, from: Data(json.utf8))
        let p = try #require(env.result?.config.personality)
        #expect(p.professionalism == "always")
        #expect(p.warmth == "often")
        #expect(p.directness == "often")
        #expect(p.enthusiasm == "sometimes")
        #expect(p.humor == "sometimes")
        #expect(p.sarcasm == "rarely")
        #expect(p.pretentiousness == "rarely")
    }

    @Test func configWithoutPersonalityDecodesToNilPersonality() throws {
        // Older daemon reply that omits the personality block (Config's
        // `#[serde(default)]` means it can be absent). Our loose decode models
        // it as optional so this stays decodable, yielding no dials.
        let json = """
        {"config":{"embeddings":{"connector":"ollama","model":"m","base_url":"","has_api_key":false,"available":true,"is_default":true},"persistence":{"enabled":false,"remote_url":"","remote_name":"","push_on_update":false}}}
        """
        let payload = try JSONDecoder().decode(ConfigResultPayload.self, from: Data(json.utf8))
        #expect(payload.config.personality == nil)
    }

    @Test func personalityLevelsAllDecode() throws {
        // Every level string in the enum must decode into a dial.
        let json = #"{"professionalism":"never","warmth":"rarely","directness":"sometimes","enthusiasm":"often","humor":"always","sarcasm":"never","pretentiousness":"always"}"#
        let p = try JSONDecoder().decode(Personality.self, from: Data(json.utf8))
        #expect(p.professionalism == "never")
        #expect(p.warmth == "rarely")
        #expect(p.directness == "sometimes")
        #expect(p.enthusiasm == "often")
        #expect(p.humor == "always")
    }
}
