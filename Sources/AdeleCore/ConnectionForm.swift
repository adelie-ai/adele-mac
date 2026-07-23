import Foundation

/// The editable state of the connection add/edit sheet, kept out of the SwiftUI
/// view so the create → encode → decode → populate → edit round-trip is unit
/// testable without a daemon or a UI.
///
/// Every field is the raw, user-typed form value (strings, even for the numeric
/// knobs); `build()` trims them, drops the blanks, and assembles the
/// connector-specific `ConnectionConfigInput`. `init(config:)` is the inverse:
/// it pre-fills from a daemon-echoed config. Secrets never appear here — the API
/// key *value* travels only via `set_connection_secret`, and only the env-var
/// *name* (`apiKeyEnv`) is part of the config.
///
/// Azure and Google each get their own `authMode` field so a picker's selection
/// is always one of that connector's allowed values (a single shared field would
/// leave the picker with no matching tag after switching connector type).
public struct ConnectionFormState: Equatable, Sendable {
    public var connectorType: String

    // Shared
    public var baseURL: String = ""
    public var apiKeyEnv: String = ""
    public var connectTimeout: String = ""
    public var streamTimeout: String = ""
    public var maxTokens: String = ""

    // Bedrock
    public var awsProfile: String = ""
    public var region: String = ""

    // Ollama
    public var keepWarm: Bool = false

    // Azure
    public var apiSurface: String = ConnectionConfigInput.defaultAzureApiSurface
    public var azureAuthMode: String = ConnectionConfigInput.defaultAzureAuthMode
    public var apiVersion: String = ""

    // Google
    public var project: String = ""
    public var location: String = ""
    public var googleAuthMode: String = ConnectionConfigInput.defaultGoogleAuthMode
    public var credentialsPath: String = ""

    public init(connectorType: String = "anthropic") {
        self.connectorType = connectorType
    }

    /// Pre-fill from a daemon-echoed `ConnectionConfigView`. Fields belonging to
    /// other connector types keep their defaults.
    public init(config: ConnectionConfigInput) {
        self.init(connectorType: config.connectorType)
        baseURL = config.baseURL ?? ""
        apiKeyEnv = config.apiKeyEnv ?? ""
        connectTimeout = config.connectTimeoutSecs.map(String.init) ?? ""
        streamTimeout = config.streamTimeoutSecs.map(String.init) ?? ""
        maxTokens = config.maxContextTokens.map(String.init) ?? ""
        awsProfile = config.awsProfile ?? ""
        region = config.region ?? ""
        keepWarm = config.keepWarm ?? false
        apiSurface = config.apiSurface ?? ConnectionConfigInput.defaultAzureApiSurface
        apiVersion = config.apiVersion ?? ""
        project = config.project ?? ""
        location = config.location ?? ""
        credentialsPath = config.credentialsPath ?? ""
        switch config.connectorType {
        case "azure":
            azureAuthMode = config.authMode ?? ConnectionConfigInput.defaultAzureAuthMode
        case "google":
            googleAuthMode = config.authMode ?? ConnectionConfigInput.defaultGoogleAuthMode
        default:
            break
        }
    }

    /// Assemble the `ConnectionConfigView` variant for the selected connector
    /// type. Blank optional fields are omitted so the daemon applies its own
    /// documented defaults; the enum knobs (`api_surface`, `auth_mode`) always
    /// travel, because a picker always has a value.
    public func build() -> ConnectionConfigInput {
        let base = Self.trimmedOrNil(baseURL)
        let keyEnv = Self.trimmedOrNil(apiKeyEnv)
        let ct = UInt64(connectTimeout.trimmingCharacters(in: .whitespaces))
        let st = UInt64(streamTimeout.trimmingCharacters(in: .whitespaces))
        let mt = UInt64(maxTokens.trimmingCharacters(in: .whitespaces))
        switch connectorType {
        case "openai":
            return .openai(baseURL: base, apiKeyEnv: keyEnv,
                           connectTimeoutSecs: ct, streamTimeoutSecs: st, maxContextTokens: mt)
        case "openrouter":
            return .openrouter(baseURL: base, apiKeyEnv: keyEnv,
                               connectTimeoutSecs: ct, streamTimeoutSecs: st, maxContextTokens: mt)
        case "azure":
            return .azure(baseURL: base, apiKeyEnv: keyEnv,
                          apiSurface: apiSurface, authMode: azureAuthMode,
                          apiVersion: Self.trimmedOrNil(apiVersion),
                          connectTimeoutSecs: ct, streamTimeoutSecs: st, maxContextTokens: mt)
        case "google":
            return .google(baseURL: base, apiKeyEnv: keyEnv,
                           project: Self.trimmedOrNil(project),
                           location: Self.trimmedOrNil(location),
                           authMode: googleAuthMode,
                           credentialsPath: Self.trimmedOrNil(credentialsPath),
                           connectTimeoutSecs: ct, streamTimeoutSecs: st, maxContextTokens: mt)
        case "bedrock":
            return .bedrock(awsProfile: Self.trimmedOrNil(awsProfile),
                            region: Self.trimmedOrNil(region), baseURL: base,
                            connectTimeoutSecs: ct, streamTimeoutSecs: st, maxContextTokens: mt)
        case "ollama":
            return .ollama(baseURL: base, connectTimeoutSecs: ct, streamTimeoutSecs: st,
                           keepWarm: keepWarm, maxContextTokens: mt)
        default:
            return .anthropic(baseURL: base, apiKeyEnv: keyEnv,
                              connectTimeoutSecs: ct, streamTimeoutSecs: st, maxContextTokens: mt)
        }
    }

    // MARK: Field visibility

    /// True when this connector authenticates with an API key, so the sheet
    /// should offer `api_key_env` + the secret field. Azure with Entra ID and
    /// Google with Vertex both authenticate ambiently instead.
    public var usesApiKey: Bool {
        switch connectorType {
        case "anthropic", "openai", "openrouter": return true
        case "azure": return azureAuthMode == "api_key"
        case "google": return googleAuthMode == "api_key"
        default: return false
        }
    }

    /// True when Google is in Vertex mode, which uses a service-account JSON
    /// path (or ADC) plus project/location rather than a key.
    public var usesVertexCredentials: Bool {
        connectorType == "google" && googleAuthMode == "vertex"
    }

    /// `api_version` only applies to Azure's legacy `classic` surface.
    public var usesAzureApiVersion: Bool {
        connectorType == "azure" && apiSurface == "classic"
    }

    /// The base-URL placeholder for the selected connector.
    public var baseURLPrompt: String {
        switch connectorType {
        case "azure": return "Resource endpoint, e.g. https://<name>.openai.azure.com"
        case "google": return "Base URL (optional — composed from the location)"
        default:
            if let url = ConnectionConfigInput.defaultBaseURL(for: connectorType) {
                return "Base URL (default \(url))"
            }
            return "Base URL (optional override)"
        }
    }

    /// The `api_key_env` placeholder for the selected connector.
    public var apiKeyEnvPrompt: String {
        if let env = ConnectionConfigInput.defaultApiKeyEnv(for: connectorType) {
            return "API key env var (default \(env))"
        }
        return "API key env var (api_key_env)"
    }

    private static func trimmedOrNil(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
