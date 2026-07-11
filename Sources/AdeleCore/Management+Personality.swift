import Foundation

// MARK: - Personality view type (mirrors desktop-assistant protocol::Personality)

/// Adele's configurable disposition — the "Expressive 7" trait dials (issue #226).
///
/// Each dial is an optional snake_case level string
/// (`"never" | "rarely" | "sometimes" | "often" | "always"`), matching
/// `protocol::PersonalityLevel` (`#[serde(rename_all = "lowercase")]`). The
/// values are optional here for two reasons: on READ every dial is populated by
/// the daemon (its `Config.personality` is a complete `Personality`), but on
/// WRITE a `nil` dial means "leave this trait unchanged" — the same partial
/// semantics as `ConfigChanges`'s `Option<PersonalityLevel>` fields. Modeling a
/// dial as a plain `String?` (rather than a Swift enum) keeps the client tolerant
/// of any future level the daemon adds without a decode failure.
public struct Personality: Decodable, Hashable, Sendable {
    public var professionalism: String?
    public var warmth: String?
    public var directness: String?
    public var enthusiasm: String?
    public var humor: String?
    public var sarcasm: String?
    public var pretentiousness: String?

    public init(
        professionalism: String? = nil,
        warmth: String? = nil,
        directness: String? = nil,
        enthusiasm: String? = nil,
        humor: String? = nil,
        sarcasm: String? = nil,
        pretentiousness: String? = nil
    ) {
        self.professionalism = professionalism
        self.warmth = warmth
        self.directness = directness
        self.enthusiasm = enthusiasm
        self.humor = humor
        self.sarcasm = sarcasm
        self.pretentiousness = pretentiousness
    }

    /// The trait names in stable display order (matches the daemon's field
    /// order). The editor pairs these with key paths on its own side (key paths
    /// aren't `Sendable`, so they can't live on this cross-actor value type).
    public static let traitNames = [
        "professionalism", "warmth", "directness", "enthusiasm",
        "humor", "sarcasm", "pretentiousness",
    ]

    /// The 5 selectable levels, weakest → strongest.
    public static let levels = ["never", "rarely", "sometimes", "often", "always"]
}

/// Loose decode of the `GetConfig` reply payload (`CommandResult::Config`). Only
/// the personality subset is modeled; the other `Config` sections (embeddings,
/// persistence) are intentionally ignored. `personality` is optional so a daemon
/// that omits the block (`Config.personality` is `#[serde(default)]`) still
/// decodes cleanly.
struct ConfigResultPayload: Decodable {
    struct ConfigView: Decodable {
        let personality: Personality?
    }
    let config: ConfigView
}

// MARK: - Typed personality commands over the generic bridge

extension AdeleCore {
    /// Read the global personality dials via `GetConfig`, extracting just the
    /// `config.personality` subset. Returns an all-nil `Personality` if the
    /// daemon omits the block.
    @MainActor
    public func getPersonality() async throws -> Personality {
        let data = try await sendCommand(AdeleCommand.getConfig)
        let envelope = try JSONDecoder().decode(
            CommandResultEnvelope<ConfigResultPayload>.self, from: data)
        return envelope.result?.config.personality ?? Personality()
    }

    /// Write the personality dials via `SetConfig`. Only non-nil dials are sent
    /// (each an `personality_<trait>` change); nil dials are left unchanged. The
    /// daemon replies `CommandResult::Ack`, which we treat as success (a failure
    /// throws inside `sendCommand`).
    @MainActor
    public func setPersonality(_ personality: Personality) async throws {
        _ = try await sendCommand(AdeleCommand.setPersonality(personality))
    }
}
