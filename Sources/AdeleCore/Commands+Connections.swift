import Foundation

/// Client-side model for the daemon's `ConnectionConfigView` (api-model). Unlike
/// the outer `api::Command` (externally tagged), this type is **internally
/// tagged**: it serializes as `{"type":"<lowercase>", ...}` with every unset
/// field omitted (matching serde `skip_serializing_if = "Option::is_none"`).
/// It is `Codable` so an edit dialog can also pre-fill from a daemon-echoed
/// config. All numeric fields are `UInt64` to mirror the Rust `u64`.
public enum ConnectionConfigInput: Codable, Equatable, Hashable, Sendable {
    case anthropic(
        baseURL: String? = nil,
        apiKeyEnv: String? = nil,
        connectTimeoutSecs: UInt64? = nil,
        streamTimeoutSecs: UInt64? = nil,
        maxContextTokens: UInt64? = nil
    )
    case openai(
        baseURL: String? = nil,
        apiKeyEnv: String? = nil,
        connectTimeoutSecs: UInt64? = nil,
        streamTimeoutSecs: UInt64? = nil,
        maxContextTokens: UInt64? = nil
    )
    /// OpenRouter carries the same non-secret fields as `.openai`.
    case openrouter(
        baseURL: String? = nil,
        apiKeyEnv: String? = nil,
        connectTimeoutSecs: UInt64? = nil,
        streamTimeoutSecs: UInt64? = nil,
        maxContextTokens: UInt64? = nil
    )
    /// Azure OpenAI: the OpenAI-compatible fields plus surface/auth/version knobs.
    /// `baseURL` is the *resource* endpoint (`https://<name>.openai.azure.com`)
    /// and has no default; `apiVersion` only applies on the `classic` surface.
    case azure(
        baseURL: String? = nil,
        apiKeyEnv: String? = nil,
        apiSurface: String? = nil,
        authMode: String? = nil,
        apiVersion: String? = nil,
        connectTimeoutSecs: UInt64? = nil,
        streamTimeoutSecs: UInt64? = nil,
        maxContextTokens: UInt64? = nil
    )
    /// Google Vertex AI (default) / Gemini API: project + region + auth knobs.
    /// `baseURL` is usually blank — the connector composes the Vertex host from
    /// `location`. `credentialsPath` is a filesystem path, not a secret.
    case google(
        baseURL: String? = nil,
        apiKeyEnv: String? = nil,
        project: String? = nil,
        location: String? = nil,
        authMode: String? = nil,
        credentialsPath: String? = nil,
        connectTimeoutSecs: UInt64? = nil,
        streamTimeoutSecs: UInt64? = nil,
        maxContextTokens: UInt64? = nil
    )
    case bedrock(
        awsProfile: String? = nil,
        region: String? = nil,
        baseURL: String? = nil,
        connectTimeoutSecs: UInt64? = nil,
        streamTimeoutSecs: UInt64? = nil,
        maxContextTokens: UInt64? = nil
    )
    case ollama(
        baseURL: String? = nil,
        connectTimeoutSecs: UInt64? = nil,
        streamTimeoutSecs: UInt64? = nil,
        keepWarm: Bool? = nil,
        maxContextTokens: UInt64? = nil
    )

    private enum CodingKeys: String, CodingKey {
        case type
        case baseURL = "base_url"
        case apiKeyEnv = "api_key_env"
        case connectTimeoutSecs = "connect_timeout_secs"
        case streamTimeoutSecs = "stream_timeout_secs"
        case maxContextTokens = "max_context_tokens"
        case awsProfile = "aws_profile"
        case region
        case keepWarm = "keep_warm"
        case apiSurface = "api_surface"
        case authMode = "auth_mode"
        case apiVersion = "api_version"
        case project
        case location
        case credentialsPath = "credentials_path"
    }

    // MARK: Accessors (for pre-filling / rendering an edit form)

    /// The internal `type` tag (`"anthropic"`, `"openai"`, `"openrouter"`,
    /// `"azure"`, `"google"`, `"bedrock"`, `"ollama"`).
    public var connectorType: String {
        switch self {
        case .anthropic: return "anthropic"
        case .openai: return "openai"
        case .openrouter: return "openrouter"
        case .azure: return "azure"
        case .google: return "google"
        case .bedrock: return "bedrock"
        case .ollama: return "ollama"
        }
    }

    public var baseURL: String? {
        switch self {
        case let .anthropic(b, _, _, _, _), let .openai(b, _, _, _, _),
             let .openrouter(b, _, _, _, _): return b
        case let .azure(b, _, _, _, _, _, _, _): return b
        case let .google(b, _, _, _, _, _, _, _, _): return b
        case let .bedrock(_, _, b, _, _, _): return b
        case let .ollama(b, _, _, _, _): return b
        }
    }

    /// Bedrock and Ollama carry no credential env-var name.
    public var apiKeyEnv: String? {
        switch self {
        case let .anthropic(_, k, _, _, _), let .openai(_, k, _, _, _),
             let .openrouter(_, k, _, _, _): return k
        case let .azure(_, k, _, _, _, _, _, _): return k
        case let .google(_, k, _, _, _, _, _, _, _): return k
        default: return nil
        }
    }

    /// Azure only: `"v1"` (default) or `"classic"`.
    public var apiSurface: String? {
        if case let .azure(_, _, s, _, _, _, _, _) = self { return s }
        return nil
    }

    /// Azure (`"api_key"` | `"entra"`) or Google (`"vertex"` | `"api_key"`).
    public var authMode: String? {
        switch self {
        case let .azure(_, _, _, a, _, _, _, _): return a
        case let .google(_, _, _, _, a, _, _, _, _): return a
        default: return nil
        }
    }

    /// Azure only, and only meaningful on the `classic` surface.
    public var apiVersion: String? {
        if case let .azure(_, _, _, _, v, _, _, _) = self { return v }
        return nil
    }

    /// Google only: the GCP project id (Vertex).
    public var project: String? {
        if case let .google(_, _, p, _, _, _, _, _, _) = self { return p }
        return nil
    }

    /// Google only: the Vertex region, e.g. `us-central1`.
    public var location: String? {
        if case let .google(_, _, _, l, _, _, _, _, _) = self { return l }
        return nil
    }

    /// Google only: path to a service-account JSON key (falls back to ADC).
    public var credentialsPath: String? {
        if case let .google(_, _, _, _, _, p, _, _, _) = self { return p }
        return nil
    }

    public var awsProfile: String? {
        if case let .bedrock(p, _, _, _, _, _) = self { return p }
        return nil
    }

    public var region: String? {
        if case let .bedrock(_, r, _, _, _, _) = self { return r }
        return nil
    }

    public var keepWarm: Bool? {
        if case let .ollama(_, _, _, w, _) = self { return w }
        return nil
    }

    public var connectTimeoutSecs: UInt64? {
        switch self {
        case let .anthropic(_, _, c, _, _), let .openai(_, _, c, _, _),
             let .openrouter(_, _, c, _, _): return c
        case let .azure(_, _, _, _, _, c, _, _): return c
        case let .google(_, _, _, _, _, _, c, _, _): return c
        case let .bedrock(_, _, _, c, _, _): return c
        case let .ollama(_, c, _, _, _): return c
        }
    }

    public var streamTimeoutSecs: UInt64? {
        switch self {
        case let .anthropic(_, _, _, s, _), let .openai(_, _, _, s, _),
             let .openrouter(_, _, _, s, _): return s
        case let .azure(_, _, _, _, _, _, s, _): return s
        case let .google(_, _, _, _, _, _, _, s, _): return s
        case let .bedrock(_, _, _, _, s, _): return s
        case let .ollama(_, _, s, _, _): return s
        }
    }

    public var maxContextTokens: UInt64? {
        switch self {
        case let .anthropic(_, _, _, _, m), let .openai(_, _, _, _, m),
             let .openrouter(_, _, _, _, m): return m
        case let .azure(_, _, _, _, _, _, _, m): return m
        case let .google(_, _, _, _, _, _, _, _, m): return m
        case let .bedrock(_, _, _, _, _, m): return m
        case let .ollama(_, _, _, _, m): return m
        }
    }

    // MARK: Codable (internally tagged, nil fields omitted)

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(connectorType, forKey: .type)
        switch self {
        case let .anthropic(baseURL, apiKeyEnv, connectT, streamT, maxTokens),
             let .openai(baseURL, apiKeyEnv, connectT, streamT, maxTokens),
             let .openrouter(baseURL, apiKeyEnv, connectT, streamT, maxTokens):
            try c.encodeIfPresent(baseURL, forKey: .baseURL)
            try c.encodeIfPresent(apiKeyEnv, forKey: .apiKeyEnv)
            try c.encodeIfPresent(connectT, forKey: .connectTimeoutSecs)
            try c.encodeIfPresent(streamT, forKey: .streamTimeoutSecs)
            try c.encodeIfPresent(maxTokens, forKey: .maxContextTokens)
        case let .azure(baseURL, apiKeyEnv, apiSurface, authMode, apiVersion, connectT, streamT, maxTokens):
            try c.encodeIfPresent(baseURL, forKey: .baseURL)
            try c.encodeIfPresent(apiKeyEnv, forKey: .apiKeyEnv)
            try c.encodeIfPresent(apiSurface, forKey: .apiSurface)
            try c.encodeIfPresent(authMode, forKey: .authMode)
            try c.encodeIfPresent(apiVersion, forKey: .apiVersion)
            try c.encodeIfPresent(connectT, forKey: .connectTimeoutSecs)
            try c.encodeIfPresent(streamT, forKey: .streamTimeoutSecs)
            try c.encodeIfPresent(maxTokens, forKey: .maxContextTokens)
        case let .google(baseURL, apiKeyEnv, project, location, authMode, credentialsPath, connectT, streamT, maxTokens):
            try c.encodeIfPresent(baseURL, forKey: .baseURL)
            try c.encodeIfPresent(apiKeyEnv, forKey: .apiKeyEnv)
            try c.encodeIfPresent(project, forKey: .project)
            try c.encodeIfPresent(location, forKey: .location)
            try c.encodeIfPresent(authMode, forKey: .authMode)
            try c.encodeIfPresent(credentialsPath, forKey: .credentialsPath)
            try c.encodeIfPresent(connectT, forKey: .connectTimeoutSecs)
            try c.encodeIfPresent(streamT, forKey: .streamTimeoutSecs)
            try c.encodeIfPresent(maxTokens, forKey: .maxContextTokens)
        case let .bedrock(awsProfile, region, baseURL, connectT, streamT, maxTokens):
            try c.encodeIfPresent(awsProfile, forKey: .awsProfile)
            try c.encodeIfPresent(region, forKey: .region)
            try c.encodeIfPresent(baseURL, forKey: .baseURL)
            try c.encodeIfPresent(connectT, forKey: .connectTimeoutSecs)
            try c.encodeIfPresent(streamT, forKey: .streamTimeoutSecs)
            try c.encodeIfPresent(maxTokens, forKey: .maxContextTokens)
        case let .ollama(baseURL, connectT, streamT, keepWarm, maxTokens):
            try c.encodeIfPresent(baseURL, forKey: .baseURL)
            try c.encodeIfPresent(connectT, forKey: .connectTimeoutSecs)
            try c.encodeIfPresent(streamT, forKey: .streamTimeoutSecs)
            try c.encodeIfPresent(keepWarm, forKey: .keepWarm)
            try c.encodeIfPresent(maxTokens, forKey: .maxContextTokens)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        let baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL)
        let apiKeyEnv = try c.decodeIfPresent(String.self, forKey: .apiKeyEnv)
        let connectT = try c.decodeIfPresent(UInt64.self, forKey: .connectTimeoutSecs)
        let streamT = try c.decodeIfPresent(UInt64.self, forKey: .streamTimeoutSecs)
        let maxTokens = try c.decodeIfPresent(UInt64.self, forKey: .maxContextTokens)
        switch type {
        case "anthropic":
            self = .anthropic(baseURL: baseURL, apiKeyEnv: apiKeyEnv, connectTimeoutSecs: connectT, streamTimeoutSecs: streamT, maxContextTokens: maxTokens)
        case "openai":
            self = .openai(baseURL: baseURL, apiKeyEnv: apiKeyEnv, connectTimeoutSecs: connectT, streamTimeoutSecs: streamT, maxContextTokens: maxTokens)
        case "openrouter":
            self = .openrouter(baseURL: baseURL, apiKeyEnv: apiKeyEnv, connectTimeoutSecs: connectT, streamTimeoutSecs: streamT, maxContextTokens: maxTokens)
        case "azure":
            self = .azure(
                baseURL: baseURL,
                apiKeyEnv: apiKeyEnv,
                apiSurface: try c.decodeIfPresent(String.self, forKey: .apiSurface),
                authMode: try c.decodeIfPresent(String.self, forKey: .authMode),
                apiVersion: try c.decodeIfPresent(String.self, forKey: .apiVersion),
                connectTimeoutSecs: connectT, streamTimeoutSecs: streamT, maxContextTokens: maxTokens
            )
        case "google":
            self = .google(
                baseURL: baseURL,
                apiKeyEnv: apiKeyEnv,
                project: try c.decodeIfPresent(String.self, forKey: .project),
                location: try c.decodeIfPresent(String.self, forKey: .location),
                authMode: try c.decodeIfPresent(String.self, forKey: .authMode),
                credentialsPath: try c.decodeIfPresent(String.self, forKey: .credentialsPath),
                connectTimeoutSecs: connectT, streamTimeoutSecs: streamT, maxContextTokens: maxTokens
            )
        case "bedrock":
            let awsProfile = try c.decodeIfPresent(String.self, forKey: .awsProfile)
            let region = try c.decodeIfPresent(String.self, forKey: .region)
            self = .bedrock(awsProfile: awsProfile, region: region, baseURL: baseURL, connectTimeoutSecs: connectT, streamTimeoutSecs: streamT, maxContextTokens: maxTokens)
        case "ollama":
            let keepWarm = try c.decodeIfPresent(Bool.self, forKey: .keepWarm)
            self = .ollama(baseURL: baseURL, connectTimeoutSecs: connectT, streamTimeoutSecs: streamT, keepWarm: keepWarm, maxContextTokens: maxTokens)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "unknown connector type \"\(type)\""
            )
        }
    }

    // MARK: Connector-type metadata (picker labels, documented defaults)

    /// Every connector type this client can create, in display order (matches
    /// the api-model `ConnectionConfigView` variant order).
    public static let allConnectorTypes = [
        "anthropic", "openai", "openrouter", "azure", "google", "bedrock", "ollama",
    ]

    /// Allowed values for Azure's `api_surface`: the v1 GA API, or the legacy
    /// `deployments/{name}` path that still needs an `api_version`.
    public static let azureApiSurfaces = ["v1", "classic"]
    public static let defaultAzureApiSurface = "v1"

    /// Allowed values for Azure's `auth_mode`: an api key, or Entra ID /
    /// managed identity (ambient token, no key needed).
    public static let azureAuthModes = ["api_key", "entra"]
    public static let defaultAzureAuthMode = "api_key"

    /// Allowed values for Google's `auth_mode`: Vertex AI (OAuth2 / ADC or a
    /// service account) or the AI Studio Gemini API (api key).
    public static let googleAuthModes = ["vertex", "api_key"]
    public static let defaultGoogleAuthMode = "vertex"

    /// Human-friendly picker label for a connector type.
    public static func displayName(for type: String) -> String {
        switch type {
        case "anthropic": return "Anthropic"
        case "openai": return "OpenAI"
        case "openrouter": return "OpenRouter"
        case "azure": return "Azure OpenAI"
        case "google": return "Google (Vertex AI / Gemini)"
        case "bedrock": return "AWS Bedrock"
        case "ollama": return "Ollama"
        default: return type.capitalized
        }
    }

    /// The connector's documented default endpoint, shown as a placeholder.
    /// `nil` where there is no sensible default: Azure's endpoint is
    /// resource-specific and required, and Google composes the Vertex host from
    /// `location`.
    public static func defaultBaseURL(for type: String) -> String? {
        switch type {
        case "anthropic": return "https://api.anthropic.com"
        case "openai": return "https://api.openai.com/v1"
        case "openrouter": return "https://openrouter.ai/api/v1"
        case "ollama": return "http://localhost:11434"
        default: return nil
        }
    }

    /// The connector's documented default credential env-var name, shown as a
    /// placeholder. `nil` for connectors that authenticate ambiently.
    public static func defaultApiKeyEnv(for type: String) -> String? {
        switch type {
        case "anthropic": return "ANTHROPIC_API_KEY"
        case "openai": return "OPENAI_API_KEY"
        case "openrouter": return "OPENROUTER_API_KEY"
        case "azure": return "AZURE_OPENAI_API_KEY"
        case "google": return "GOOGLE_API_KEY"
        default: return nil
        }
    }
}

// MARK: - Connection command builders (issue #11)

extension AdeleCommand {
    /// `{"create_connection":{"id":"<slug>","config":<ConnectionConfigView>}}`
    public static func createConnection(id: String, config: ConnectionConfigInput) -> String {
        struct Cmd: Encodable {
            struct P: Encodable { let id: String; let config: ConnectionConfigInput }
            let create_connection: P
        }
        return encode(Cmd(create_connection: .init(id: id, config: config)))
    }

    /// `{"update_connection":{"id":"<slug>","config":<ConnectionConfigView>}}`
    public static func updateConnection(id: String, config: ConnectionConfigInput) -> String {
        struct Cmd: Encodable {
            struct P: Encodable { let id: String; let config: ConnectionConfigInput }
            let update_connection: P
        }
        return encode(Cmd(update_connection: .init(id: id, config: config)))
    }

    /// `{"delete_connection":{"id":"<slug>","force":<bool>}}`
    public static func deleteConnection(id: String, force: Bool) -> String {
        struct Cmd: Encodable {
            struct P: Encodable { let id: String; let force: Bool }
            let delete_connection: P
        }
        return encode(Cmd(delete_connection: .init(id: id, force: force)))
    }

    /// Store (or clear) a connection's raw credential in the daemon's secret
    /// store (never in daemon.toml, never echoed back). Empty `credential`
    /// clears it. For Bedrock the value is
    /// `ACCESS_KEY_ID:SECRET_ACCESS_KEY[:SESSION_TOKEN]`; for api-key connectors
    /// it is the raw key.
    /// `{"set_connection_secret":{"id":"<slug>","credential":"..."}}`
    public static func setConnectionSecret(id: String, credential: String) -> String {
        struct Cmd: Encodable {
            struct P: Encodable { let id: String; let credential: String }
            let set_connection_secret: P
        }
        return encode(Cmd(set_connection_secret: .init(id: id, credential: credential)))
    }
}
