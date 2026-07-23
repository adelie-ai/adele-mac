import Testing
import Foundation
@testable import AdeleCore

/// Spec (issue #9): the three cloud LLM connectors added by
/// `desktop-assistant#592` — **OpenRouter** (OpenAI-shaped), **Azure** (Azure
/// OpenAI, with `api_surface`/`auth_mode`/`api_version`) and **Google**
/// (Vertex AI / Gemini, with `project`/`location`/`auth_mode`/`credentials_path`).
///
/// These cover the wire shape of the new `ConnectionConfigView` variants, the
/// pure form model that backs the editor sheet (create → encode → decode →
/// populate form → edit round-trip), that an *existing* connection of each type
/// decodes for display, and that the daemon's auth-aware preflight reason is
/// carried through to something the UI can show.
@Suite struct CloudConnectorTests {
    private func object(_ json: String) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try #require(value as? [String: Any])
    }

    private func config(_ json: String, key: String = "create_connection") throws -> [String: Any] {
        let root = try object(json)
        let payload = try #require(root[key] as? [String: Any])
        return try #require(payload["config"] as? [String: Any])
    }

    /// Encode a config through `create_connection` and decode it straight back —
    /// the daemon's create → list → edit path in miniature.
    private func roundTrip(_ config: ConnectionConfigInput) throws -> ConnectionConfigInput {
        let json = AdeleCommand.createConnection(id: "x", config: config)
        let dict = try self.config(json)
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(ConnectionConfigInput.self, from: data)
    }

    // MARK: - Picker

    @Test func pickerOffersAllSevenConnectorTypes() {
        #expect(ConnectionConfigInput.allConnectorTypes == [
            "anthropic", "openai", "openrouter", "azure", "google", "bedrock", "ollama",
        ])
    }

    @Test func newConnectorTypesHaveDisplayNames() {
        #expect(ConnectionConfigInput.displayName(for: "openrouter") == "OpenRouter")
        #expect(ConnectionConfigInput.displayName(for: "azure") == "Azure OpenAI")
        #expect(ConnectionConfigInput.displayName(for: "google") == "Google (Vertex AI / Gemini)")
    }

    @Test func enumFieldOptionsMatchTheDaemon() {
        #expect(ConnectionConfigInput.azureApiSurfaces == ["v1", "classic"])
        #expect(ConnectionConfigInput.azureAuthModes == ["api_key", "entra"])
        #expect(ConnectionConfigInput.googleAuthModes == ["vertex", "api_key"])
        #expect(ConnectionConfigInput.defaultAzureApiSurface == "v1")
        #expect(ConnectionConfigInput.defaultAzureAuthMode == "api_key")
        #expect(ConnectionConfigInput.defaultGoogleAuthMode == "vertex")
    }

    @Test func documentedDefaultsAreOfferedAsHints() {
        #expect(ConnectionConfigInput.defaultBaseURL(for: "openrouter") == "https://openrouter.ai/api/v1")
        // Azure's resource endpoint is per-resource: there is no default host.
        #expect(ConnectionConfigInput.defaultBaseURL(for: "azure") == nil)
        // Google composes the Vertex host from `location`.
        #expect(ConnectionConfigInput.defaultBaseURL(for: "google") == nil)
        #expect(ConnectionConfigInput.defaultApiKeyEnv(for: "openrouter") == "OPENROUTER_API_KEY")
        #expect(ConnectionConfigInput.defaultApiKeyEnv(for: "azure") == "AZURE_OPENAI_API_KEY")
        #expect(ConnectionConfigInput.defaultApiKeyEnv(for: "google") == "GOOGLE_API_KEY")
        #expect(ConnectionConfigInput.defaultApiKeyEnv(for: "ollama") == nil)
    }

    // MARK: - OpenRouter (OpenAI-shaped)

    @Test func createOpenRouterCarriesTheOpenAiFieldSet() throws {
        let json = AdeleCommand.createConnection(
            id: "router",
            config: .openrouter(
                baseURL: "https://openrouter.ai/api/v1",
                apiKeyEnv: "OPENROUTER_API_KEY",
                connectTimeoutSecs: 10,
                streamTimeoutSecs: 300,
                maxContextTokens: 200_000
            )
        )
        let config = try config(json)
        #expect(config["type"] as? String == "openrouter")
        #expect(config["base_url"] as? String == "https://openrouter.ai/api/v1")
        #expect(config["api_key_env"] as? String == "OPENROUTER_API_KEY")
        #expect(config["connect_timeout_secs"] as? Int == 10)
        #expect(config["stream_timeout_secs"] as? Int == 300)
        #expect(config["max_context_tokens"] as? Int == 200_000)
        // OpenAI-shaped: no azure/google/bedrock/ollama fields leak in.
        #expect(config["api_surface"] == nil)
        #expect(config["auth_mode"] == nil)
        #expect(config["project"] == nil)
        #expect(config["aws_profile"] == nil)
        #expect(config.keys.count == 6)
    }

    @Test func openRouterOmitsUnsetFields() throws {
        let config = try config(AdeleCommand.createConnection(id: "r", config: .openrouter()))
        #expect(config["type"] as? String == "openrouter")
        #expect(config.keys.count == 1, "only the type tag should remain")
    }

    // MARK: - Azure

    @Test func createAzureCarriesSurfaceAuthAndVersion() throws {
        let json = AdeleCommand.createConnection(
            id: "az",
            config: .azure(
                baseURL: "https://contoso.openai.azure.com",
                apiKeyEnv: "AZURE_OPENAI_API_KEY",
                apiSurface: "classic",
                authMode: "entra",
                apiVersion: "2024-10-21",
                connectTimeoutSecs: 15,
                streamTimeoutSecs: 600,
                maxContextTokens: 128_000
            )
        )
        let config = try config(json)
        #expect(config["type"] as? String == "azure")
        #expect(config["base_url"] as? String == "https://contoso.openai.azure.com")
        #expect(config["api_key_env"] as? String == "AZURE_OPENAI_API_KEY")
        #expect(config["api_surface"] as? String == "classic")
        #expect(config["auth_mode"] as? String == "entra")
        #expect(config["api_version"] as? String == "2024-10-21")
        #expect(config["connect_timeout_secs"] as? Int == 15)
        #expect(config["stream_timeout_secs"] as? Int == 600)
        #expect(config["max_context_tokens"] as? Int == 128_000)
        #expect(config["project"] == nil)
        #expect(config.keys.count == 9)
    }

    @Test func azureOmitsUnsetFields() throws {
        let config = try config(AdeleCommand.createConnection(id: "az", config: .azure()))
        #expect(config["type"] as? String == "azure")
        #expect(config.keys.count == 1)
    }

    // MARK: - Google

    @Test func createGoogleCarriesProjectLocationAuthAndCredentials() throws {
        let json = AdeleCommand.createConnection(
            id: "vertex",
            config: .google(
                baseURL: "https://us-central1-aiplatform.googleapis.com",
                apiKeyEnv: "GOOGLE_API_KEY",
                project: "my-gcp-project",
                location: "us-central1",
                authMode: "vertex",
                credentialsPath: "/Users/dave/sa.json",
                connectTimeoutSecs: 20,
                streamTimeoutSecs: 900,
                maxContextTokens: 1_048_576
            )
        )
        let config = try config(json)
        #expect(config["type"] as? String == "google")
        #expect(config["base_url"] as? String == "https://us-central1-aiplatform.googleapis.com")
        #expect(config["api_key_env"] as? String == "GOOGLE_API_KEY")
        #expect(config["project"] as? String == "my-gcp-project")
        #expect(config["location"] as? String == "us-central1")
        #expect(config["auth_mode"] as? String == "vertex")
        #expect(config["credentials_path"] as? String == "/Users/dave/sa.json")
        #expect(config["connect_timeout_secs"] as? Int == 20)
        #expect(config["stream_timeout_secs"] as? Int == 900)
        #expect(config["max_context_tokens"] as? Int == 1_048_576)
        #expect(config["api_surface"] == nil)
        #expect(config.keys.count == 10)
    }

    @Test func googleOmitsUnsetFields() throws {
        let config = try config(AdeleCommand.createConnection(id: "g", config: .google()))
        #expect(config["type"] as? String == "google")
        #expect(config.keys.count == 1)
    }

    // MARK: - Decode (daemon-echoed config pre-fills an edit dialog)

    @Test func decodeInternallyTaggedOpenRouter() throws {
        let json = #"{"type":"openrouter","base_url":"https://openrouter.ai/api/v1","api_key_env":"OPENROUTER_API_KEY","max_context_tokens":200000}"#
        let cfg = try JSONDecoder().decode(ConnectionConfigInput.self, from: Data(json.utf8))
        #expect(cfg.connectorType == "openrouter")
        #expect(cfg.baseURL == "https://openrouter.ai/api/v1")
        #expect(cfg.apiKeyEnv == "OPENROUTER_API_KEY")
        #expect(cfg.maxContextTokens == 200_000)
    }

    @Test func decodeInternallyTaggedAzure() throws {
        let json = #"{"type":"azure","base_url":"https://contoso.openai.azure.com","api_key_env":"AZURE_OPENAI_API_KEY","api_surface":"classic","auth_mode":"entra","api_version":"2024-10-21"}"#
        let cfg = try JSONDecoder().decode(ConnectionConfigInput.self, from: Data(json.utf8))
        #expect(cfg.connectorType == "azure")
        #expect(cfg.baseURL == "https://contoso.openai.azure.com")
        #expect(cfg.apiKeyEnv == "AZURE_OPENAI_API_KEY")
        #expect(cfg.apiSurface == "classic")
        #expect(cfg.authMode == "entra")
        #expect(cfg.apiVersion == "2024-10-21")
    }

    @Test func decodeInternallyTaggedGoogle() throws {
        let json = #"{"type":"google","project":"p","location":"us-central1","auth_mode":"vertex","credentials_path":"/tmp/sa.json"}"#
        let cfg = try JSONDecoder().decode(ConnectionConfigInput.self, from: Data(json.utf8))
        #expect(cfg.connectorType == "google")
        #expect(cfg.project == "p")
        #expect(cfg.location == "us-central1")
        #expect(cfg.authMode == "vertex")
        #expect(cfg.credentialsPath == "/tmp/sa.json")
    }

    @Test func encodeDecodeRoundTripPreservesEveryField() throws {
        let cases: [ConnectionConfigInput] = [
            .openrouter(baseURL: "https://openrouter.ai/api/v1", apiKeyEnv: "OPENROUTER_API_KEY",
                        connectTimeoutSecs: 1, streamTimeoutSecs: 2, maxContextTokens: 3),
            .azure(baseURL: "https://r.openai.azure.com", apiKeyEnv: "AZURE_OPENAI_API_KEY",
                   apiSurface: "v1", authMode: "api_key", apiVersion: "2025-04-01-preview",
                   connectTimeoutSecs: 4, streamTimeoutSecs: 5, maxContextTokens: 6),
            .google(baseURL: "https://x", apiKeyEnv: "GOOGLE_API_KEY", project: "proj",
                    location: "europe-west4", authMode: "api_key", credentialsPath: "/k.json",
                    connectTimeoutSecs: 7, streamTimeoutSecs: 8, maxContextTokens: 9),
        ]
        for original in cases {
            #expect(try roundTrip(original) == original)
        }
    }

    // MARK: - Form model (create → encode → decode → populate form → edit)

    @Test func openRouterFormRoundTrip() throws {
        var form = ConnectionFormState(connectorType: "openrouter")
        form.baseURL = "https://openrouter.ai/api/v1"
        form.apiKeyEnv = "OPENROUTER_API_KEY"
        form.connectTimeout = "10"
        form.streamTimeout = "300"
        form.maxTokens = "200000"

        let built = form.build()
        #expect(built.connectorType == "openrouter")
        let reloaded = ConnectionFormState(config: try roundTrip(built))
        #expect(reloaded == form)
    }

    @Test func azureFormRoundTrip() throws {
        var form = ConnectionFormState(connectorType: "azure")
        form.baseURL = "https://contoso.openai.azure.com"
        form.apiKeyEnv = "AZURE_OPENAI_API_KEY"
        form.apiSurface = "classic"
        form.azureAuthMode = "entra"
        form.apiVersion = "2024-10-21"
        form.connectTimeout = "15"
        form.streamTimeout = "600"
        form.maxTokens = "128000"

        let built = form.build()
        #expect(built.connectorType == "azure")
        #expect(built.apiSurface == "classic")
        #expect(built.authMode == "entra")
        let reloaded = ConnectionFormState(config: try roundTrip(built))
        #expect(reloaded == form)
    }

    @Test func googleFormRoundTrip() throws {
        var form = ConnectionFormState(connectorType: "google")
        form.baseURL = ""
        form.apiKeyEnv = "GOOGLE_API_KEY"
        form.project = "my-gcp-project"
        form.location = "us-central1"
        form.googleAuthMode = "api_key"
        form.credentialsPath = "/Users/dave/sa.json"
        form.connectTimeout = "20"
        form.streamTimeout = "900"
        form.maxTokens = "1048576"

        let built = form.build()
        #expect(built.connectorType == "google")
        #expect(built.baseURL == nil, "a blank optional field is omitted, not sent as \"\"")
        #expect(built.authMode == "api_key")
        let reloaded = ConnectionFormState(config: try roundTrip(built))
        #expect(reloaded == form)
    }

    /// The enum knobs always travel (a picker always has a value), so the daemon
    /// records the operator's explicit choice rather than inferring a default.
    @Test func azureAndGoogleEnumKnobsAlwaysTravel() throws {
        let azure = ConnectionFormState(connectorType: "azure").build()
        #expect(azure.apiSurface == "v1")
        #expect(azure.authMode == "api_key")
        let google = ConnectionFormState(connectorType: "google").build()
        #expect(google.authMode == "vertex")
    }

    /// The pre-existing connectors keep working through the same form model.
    @Test func legacyConnectorFormRoundTrips() throws {
        var bedrock = ConnectionFormState(connectorType: "bedrock")
        bedrock.awsProfile = "default"
        bedrock.region = "us-east-1"
        #expect(ConnectionFormState(config: try roundTrip(bedrock.build())) == bedrock)

        var ollama = ConnectionFormState(connectorType: "ollama")
        ollama.baseURL = "http://localhost:11434"
        ollama.keepWarm = true
        #expect(ConnectionFormState(config: try roundTrip(ollama.build())) == ollama)

        var anthropic = ConnectionFormState(connectorType: "anthropic")
        anthropic.apiKeyEnv = "ANTHROPIC_API_KEY"
        #expect(ConnectionFormState(config: try roundTrip(anthropic.build())) == anthropic)
    }

    /// Which connectors offer an API-key credential field depends on auth mode:
    /// Azure/Entra and Google/Vertex authenticate ambiently instead.
    @Test func apiKeyFieldFollowsAuthMode() {
        #expect(ConnectionFormState(connectorType: "openrouter").usesApiKey)
        #expect(ConnectionFormState(connectorType: "azure").usesApiKey)

        var entra = ConnectionFormState(connectorType: "azure")
        entra.azureAuthMode = "entra"
        #expect(!entra.usesApiKey)

        // Google defaults to Vertex (ADC / service account), not an API key.
        #expect(!ConnectionFormState(connectorType: "google").usesApiKey)
        var studio = ConnectionFormState(connectorType: "google")
        studio.googleAuthMode = "api_key"
        #expect(studio.usesApiKey)

        #expect(!ConnectionFormState(connectorType: "ollama").usesApiKey)
        #expect(!ConnectionFormState(connectorType: "bedrock").usesApiKey)
    }

    // MARK: - Existing connections display without error

    @Test func existingConnectionsOfEachNewTypeDecodeForTheList() throws {
        let json = """
        {"connections":[
          {"id":"router","connector_type":"openrouter","display_label":"router (openrouter)",
           "availability":{"status":"ok"},"has_credentials":true,
           "config":{"type":"openrouter","base_url":"https://openrouter.ai/api/v1","api_key_env":"OPENROUTER_API_KEY"}},
          {"id":"az","connector_type":"azure","display_label":"az (azure)",
           "availability":{"status":"ok"},"has_credentials":true,
           "config":{"type":"azure","base_url":"https://contoso.openai.azure.com","api_surface":"v1","auth_mode":"api_key"}},
          {"id":"vertex","connector_type":"google","display_label":"vertex (google)",
           "availability":{"status":"ok"},"has_credentials":true,
           "config":{"type":"google","project":"p","location":"us-central1","auth_mode":"vertex"}}
        ]}
        """
        struct Payload: Decodable { let connections: [ConnectionView] }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
        #expect(payload.connections.count == 3)
        #expect(payload.connections.map(\.connectorType) == ["openrouter", "azure", "google"])
        // The echoed config must survive so the edit dialog pre-fills.
        for connection in payload.connections {
            #expect(connection.config != nil, "\(connection.connectorType) config must decode")
            #expect(connection.config?.connectorType == connection.connectorType)
        }
        #expect(payload.connections[1].config?.apiSurface == "v1")
        #expect(payload.connections[2].config?.location == "us-central1")
    }

    /// A connector type this build doesn't know must not break the list: the
    /// row still decodes, it just has no pre-fillable config.
    @Test func unknownConnectorTypeStillListsWithoutError() throws {
        let json = """
        {"id":"future","connector_type":"whatever","display_label":"future (whatever)",
         "availability":{"status":"ok"},"has_credentials":false,"config":{"type":"whatever"}}
        """
        let view = try JSONDecoder().decode(ConnectionView.self, from: Data(json.utf8))
        #expect(view.connectorType == "whatever")
        #expect(view.config == nil)
    }

    // MARK: - Preflight reasons surface

    @Test func preflightReasonsAreCarriedToTheUI() throws {
        let cases = [
            ("azure", "Azure connection needs a resource endpoint (base_url) and a deployment (model)"),
            ("google", "Vertex connection needs project and location"),
            ("openrouter", "OpenRouter connection has no credential (set OPENROUTER_API_KEY)"),
        ]
        for (type, reason) in cases {
            let json = """
            {"id":"c","connector_type":"\(type)","display_label":"c (\(type))",
             "availability":{"status":"unavailable","reason":"\(reason)"},
             "has_credentials":false,"config":{"type":"\(type)"}}
            """
            let view = try JSONDecoder().decode(ConnectionView.self, from: Data(json.utf8))
            #expect(!view.availability.isOk)
            #expect(view.availability.reason == reason)
            // What the row/sheet renders — never a silent blank.
            #expect(view.statusDetail == reason)
        }
    }

    @Test func availableConnectionHasNoStatusDetail() throws {
        let json = """
        {"id":"c","connector_type":"azure","display_label":"c (azure)",
         "availability":{"status":"ok"},"has_credentials":true,"config":{"type":"azure"}}
        """
        let view = try JSONDecoder().decode(ConnectionView.self, from: Data(json.utf8))
        #expect(view.statusDetail == nil)
    }

    /// `status: "unavailable"` with no reason still says *something*.
    @Test func missingReasonFallsBackToAGenericMessage() throws {
        let json = """
        {"id":"c","connector_type":"google","display_label":"c (google)",
         "availability":{"status":"unavailable"},"has_credentials":false}
        """
        let view = try JSONDecoder().decode(ConnectionView.self, from: Data(json.utf8))
        #expect(view.statusDetail == "unavailable")
    }
}
