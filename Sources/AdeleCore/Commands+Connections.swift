import Foundation

/// Client-side model for the daemon's `ConnectionConfigView` (api-model). Unlike
/// the outer `api::Command` (externally tagged), this type is **internally
/// tagged**: it serializes as `{"type":"<lowercase>", ...}` with every unset
/// field omitted (matching serde `skip_serializing_if = "Option::is_none"`).
/// It is `Codable` so an edit dialog can also pre-fill from a daemon-echoed
/// config. All numeric fields are `UInt64` to mirror the Rust `u64`.
public enum ConnectionConfigInput: Codable, Equatable, Sendable {
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
    }

    // MARK: Accessors (for pre-filling / rendering an edit form)

    /// The internal `type` tag (`"anthropic"`, `"openai"`, `"bedrock"`, `"ollama"`).
    public var connectorType: String {
        switch self {
        case .anthropic: return "anthropic"
        case .openai: return "openai"
        case .bedrock: return "bedrock"
        case .ollama: return "ollama"
        }
    }

    public var baseURL: String? {
        switch self {
        case let .anthropic(b, _, _, _, _), let .openai(b, _, _, _, _): return b
        case let .bedrock(_, _, b, _, _, _): return b
        case let .ollama(b, _, _, _, _): return b
        }
    }

    /// Only anthropic/openai carry a credential env-var name.
    public var apiKeyEnv: String? {
        switch self {
        case let .anthropic(_, k, _, _, _), let .openai(_, k, _, _, _): return k
        default: return nil
        }
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
        case let .anthropic(_, _, c, _, _), let .openai(_, _, c, _, _): return c
        case let .bedrock(_, _, _, c, _, _): return c
        case let .ollama(_, c, _, _, _): return c
        }
    }

    public var streamTimeoutSecs: UInt64? {
        switch self {
        case let .anthropic(_, _, _, s, _), let .openai(_, _, _, s, _): return s
        case let .bedrock(_, _, _, _, s, _): return s
        case let .ollama(_, _, s, _, _): return s
        }
    }

    public var maxContextTokens: UInt64? {
        switch self {
        case let .anthropic(_, _, _, _, m), let .openai(_, _, _, _, m): return m
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
             let .openai(baseURL, apiKeyEnv, connectT, streamT, maxTokens):
            try c.encodeIfPresent(baseURL, forKey: .baseURL)
            try c.encodeIfPresent(apiKeyEnv, forKey: .apiKeyEnv)
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

    /// The four connector types, in display order.
    public static let allConnectorTypes = ["anthropic", "openai", "bedrock", "ollama"]
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
}
