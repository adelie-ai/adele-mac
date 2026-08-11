import Foundation

// MARK: - ConversationToolGate reply payload

/// Decode of the `SetConversationToolGate` reply
/// (`CommandResult::ConversationToolGate { disabled }`).
///
/// `CommandResult` is externally tagged and snake_case, so the `result` payload
/// is `{"conversation_tool_gate": {"disabled": <bool>}}`.
struct ConversationToolGateResultPayload: Decodable {
    struct Value: Decodable {
        let disabled: Bool
    }

    let conversationToolGate: Value

    enum CodingKeys: String, CodingKey {
        case conversationToolGate = "conversation_tool_gate"
    }
}

// MARK: - The per-conversation tool-provenance gate, over the generic bridge

extension AdeleCore {
    /// Turn the tool-provenance gate off, or back on, for one conversation
    /// (desktop-assistant#1007).
    ///
    /// Returns the value the daemon stored, read from its echo rather than
    /// assumed from what was sent. A write the daemon changed or refused must
    /// not leave the control claiming a state the daemon does not hold. A daemon
    /// that answers with a plain `Ack` yields the value sent, because there is
    /// nothing better to report and the write did not fail.
    ///
    /// A failure throws inside `sendCommand`.
    @MainActor
    @discardableResult
    public func setConversationToolGate(
        conversationID: String,
        disabled: Bool
    ) async throws -> Bool {
        let data = try await sendCommand(
            AdeleCommand.setConversationToolGate(
                conversationID: conversationID, disabled: disabled))
        let envelope = try? JSONDecoder().decode(
            CommandResultEnvelope<ConversationToolGateResultPayload>.self, from: data)
        return envelope?.result?.conversationToolGate.disabled ?? disabled
    }
}
