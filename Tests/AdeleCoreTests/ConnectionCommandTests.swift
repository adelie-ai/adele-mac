import Testing
import Foundation
@testable import AdeleCore

/// Spec: `AdeleCommand` connection builders produce the exact `api::Command`
/// wire shape (externally tagged, snake_case) with an *internally* tagged
/// `ConnectionConfigView` payload (`{"type":"<lowercase>", ...}`, nil fields
/// omitted). Assertions parse the JSON and check nested structure so they're
/// robust to key ordering (the daemon is order-insensitive).
@Suite struct ConnectionCommandTests {
    private func object(_ json: String) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try #require(value as? [String: Any])
    }

    /// The `{id, config}` payload of a `create_connection`/`update_connection`.
    private func payload(_ json: String, key: String) throws -> [String: Any] {
        let root = try object(json)
        return try #require(root[key] as? [String: Any])
    }

    /// The inner internally-tagged config object of a create/update command.
    private func config(_ json: String, key: String) throws -> [String: Any] {
        let p = try payload(json, key: key)
        return try #require(p["config"] as? [String: Any])
    }

    // MARK: create_connection — one per connector type

    @Test func createAnthropicInternalTagAndOmitsNils() throws {
        let json = AdeleCommand.createConnection(
            id: "work",
            config: .anthropic(apiKeyEnv: "ANTHROPIC_API_KEY")
        )
        let payload = try payload(json, key: "create_connection")
        #expect(payload["id"] as? String == "work")
        let config = try config(json, key: "create_connection")
        #expect(config["type"] as? String == "anthropic")
        #expect(config["api_key_env"] as? String == "ANTHROPIC_API_KEY")
        // Every unset field must be omitted (serde skip_serializing_if = None).
        #expect(config["base_url"] == nil)
        #expect(config["connect_timeout_secs"] == nil)
        #expect(config["stream_timeout_secs"] == nil)
        #expect(config["max_context_tokens"] == nil)
        #expect(config.keys.count == 2)
    }

    @Test func createOpenAiLowercaseTagWithAllFields() throws {
        let json = AdeleCommand.createConnection(
            id: "oai",
            config: .openai(
                baseURL: "https://api.openai.com/v1",
                apiKeyEnv: "OPENAI_API_KEY",
                connectTimeoutSecs: 10,
                streamTimeoutSecs: 300,
                maxContextTokens: 128_000
            )
        )
        let config = try config(json, key: "create_connection")
        #expect(config["type"] as? String == "openai")
        #expect(config["base_url"] as? String == "https://api.openai.com/v1")
        #expect(config["api_key_env"] as? String == "OPENAI_API_KEY")
        #expect(config["connect_timeout_secs"] as? Int == 10)
        #expect(config["stream_timeout_secs"] as? Int == 300)
        #expect(config["max_context_tokens"] as? Int == 128_000)
        // openai has no aws_profile/region/keep_warm.
        #expect(config["aws_profile"] == nil)
        #expect(config["region"] == nil)
        #expect(config["keep_warm"] == nil)
    }

    @Test func createBedrockHasProfileAndRegionNoApiKeyEnv() throws {
        let json = AdeleCommand.createConnection(
            id: "aws",
            config: .bedrock(awsProfile: "default", region: "us-east-1")
        )
        let config = try config(json, key: "create_connection")
        #expect(config["type"] as? String == "bedrock")
        #expect(config["aws_profile"] as? String == "default")
        #expect(config["region"] as? String == "us-east-1")
        // Bedrock has no api_key_env variant field.
        #expect(config["api_key_env"] == nil)
        #expect(config["base_url"] == nil)
    }

    @Test func createOllamaKeepWarmBool() throws {
        let json = AdeleCommand.createConnection(
            id: "local",
            config: .ollama(baseURL: "http://localhost:11434", keepWarm: true)
        )
        let config = try config(json, key: "create_connection")
        #expect(config["type"] as? String == "ollama")
        #expect(config["base_url"] as? String == "http://localhost:11434")
        #expect(config["keep_warm"] as? Bool == true)
        // Ollama has neither api_key_env nor aws_profile.
        #expect(config["api_key_env"] == nil)
        #expect(config["aws_profile"] == nil)
    }

    @Test func ollamaOmitsKeepWarmWhenNil() throws {
        let json = AdeleCommand.createConnection(id: "local", config: .ollama())
        let config = try config(json, key: "create_connection")
        #expect(config["type"] as? String == "ollama")
        #expect(config["keep_warm"] == nil)
        #expect(config.keys.count == 1, "only the type tag should remain")
    }

    // MARK: update_connection

    @Test func updateConnectionShape() throws {
        let json = AdeleCommand.updateConnection(
            id: "work",
            config: .anthropic(baseURL: "https://proxy.internal", apiKeyEnv: "KEY")
        )
        let payload = try payload(json, key: "update_connection")
        #expect(payload["id"] as? String == "work")
        let config = try config(json, key: "update_connection")
        #expect(config["type"] as? String == "anthropic")
        #expect(config["base_url"] as? String == "https://proxy.internal")
        #expect(config["api_key_env"] as? String == "KEY")
    }

    // MARK: delete_connection

    @Test func deleteConnectionForceTrue() throws {
        let payload = try payload(AdeleCommand.deleteConnection(id: "work", force: true), key: "delete_connection")
        #expect(payload["id"] as? String == "work")
        #expect(payload["force"] as? Bool == true)
    }

    @Test func deleteConnectionForceFalse() throws {
        let payload = try payload(AdeleCommand.deleteConnection(id: "work", force: false), key: "delete_connection")
        #expect(payload["id"] as? String == "work")
        #expect(payload["force"] as? Bool == false)
    }

    // MARK: ConnectionConfigInput decode (new Codable type) — used to pre-fill
    // an edit dialog from a daemon-echoed `ConnectionConfigView`.

    @Test func decodeInternallyTaggedAnthropic() throws {
        let json = #"{"type":"anthropic","api_key_env":"ANTHROPIC_API_KEY","base_url":"https://api.anthropic.com"}"#
        let cfg = try JSONDecoder().decode(ConnectionConfigInput.self, from: Data(json.utf8))
        #expect(cfg.connectorType == "anthropic")
        #expect(cfg.apiKeyEnv == "ANTHROPIC_API_KEY")
        #expect(cfg.baseURL == "https://api.anthropic.com")
    }

    @Test func decodeInternallyTaggedOllama() throws {
        let json = #"{"type":"ollama","base_url":"http://localhost:11434","keep_warm":true}"#
        let cfg = try JSONDecoder().decode(ConnectionConfigInput.self, from: Data(json.utf8))
        #expect(cfg.connectorType == "ollama")
        #expect(cfg.baseURL == "http://localhost:11434")
        #expect(cfg.keepWarm == true)
    }

    @Test func decodeInternallyTaggedBedrock() throws {
        let json = #"{"type":"bedrock","aws_profile":"default","region":"us-east-1"}"#
        let cfg = try JSONDecoder().decode(ConnectionConfigInput.self, from: Data(json.utf8))
        #expect(cfg.connectorType == "bedrock")
        #expect(cfg.awsProfile == "default")
        #expect(cfg.region == "us-east-1")
    }

    @Test func encodeDecodeRoundTrip() throws {
        let original = ConnectionConfigInput.openai(
            baseURL: "https://x", apiKeyEnv: "K", connectTimeoutSecs: 5, streamTimeoutSecs: 60, maxContextTokens: 1000
        )
        let json = AdeleCommand.createConnection(id: "x", config: original)
        let config = try config(json, key: "create_connection")
        // Re-encode just the config sub-object and decode it back.
        let configData = try JSONSerialization.data(withJSONObject: config)
        let decoded = try JSONDecoder().decode(ConnectionConfigInput.self, from: configData)
        #expect(decoded == original)
    }

    // MARK: set_connection_secret (raw credential, never in daemon.toml)

    @Test func setConnectionSecretShape() throws {
        let json = AdeleCommand.setConnectionSecret(
            id: "bedrock", credential: "AKIA123:secret456:token789"
        )
        let p = try payload(json, key: "set_connection_secret")
        #expect(p["id"] as? String == "bedrock")
        #expect(p["credential"] as? String == "AKIA123:secret456:token789")
    }

    @Test func setConnectionSecretEmptyClears() throws {
        let p = try payload(AdeleCommand.setConnectionSecret(id: "c", credential: ""), key: "set_connection_secret")
        #expect(p["credential"] as? String == "")
    }
}
