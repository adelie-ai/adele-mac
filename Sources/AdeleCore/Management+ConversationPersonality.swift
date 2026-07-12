import Foundation

// MARK: - ConversationPersonality reply payload

/// Loose decode of the `SetConversationPersonality` reply
/// (`CommandResult::ConversationPersonality(ConversationPersonalityView)`).
///
/// `CommandResult` is externally-tagged snake_case, so the `result` payload is
/// `{"conversation_personality": {<override>}}`. The echoed override is a partial
/// `PersonalityOverride`: only pinned traits are present, so it decodes cleanly
/// into the shared `Personality` type (every dial is `String?`). An all-`None`
/// echo (`{}`) means the override was cleared and the conversation falls back to
/// the global personality.
struct ConversationPersonalityResultPayload: Decodable {
    let conversationPersonality: Personality

    enum CodingKeys: String, CodingKey {
        case conversationPersonality = "conversation_personality"
    }
}

// MARK: - Typed per-conversation personality command over the generic bridge

extension AdeleCore {
    /// Pin some/all of the 7 personality dials for a single conversation,
    /// overriding the global personality for that conversation only (issue #227).
    ///
    /// `personality` is used as a partial override: each non-nil dial pins that
    /// trait for the conversation; each nil dial is omitted from the wire and
    /// falls back to the global value. Passing an all-nil `Personality` clears
    /// the override (the conversation returns to the global personality).
    ///
    /// Returns the daemon's echoed, stored override so callers can reflect the
    /// authoritative post-write state. A failure throws inside `sendCommand`.
    @MainActor
    @discardableResult
    public func setConversationPersonality(
        conversationID: String,
        _ personality: Personality
    ) async throws -> Personality {
        let data = try await sendCommand(
            AdeleCommand.setConversationPersonality(
                conversationID: conversationID, personality: personality))
        let envelope = try JSONDecoder().decode(
            CommandResultEnvelope<ConversationPersonalityResultPayload>.self, from: data)
        // If the daemon omits/!decodes the echo, treat the write as an Ack and
        // report back what we sent.
        return envelope.result?.conversationPersonality ?? personality
    }
}
