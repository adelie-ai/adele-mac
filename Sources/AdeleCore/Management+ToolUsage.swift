import Foundation

// MARK: - ToolUsage reply payload

/// Decode of the `GetToolUsage` reply
/// (`CommandResult::ToolUsage(Vec<ToolUsageView>)`).
///
/// `CommandResult` is externally tagged and snake_case, and this variant is a
/// newtype, so the `result` payload is `{"tool_usage": [ ... ]}`.
struct ToolUsageResultPayload: Decodable {
    let toolUsage: [ToolUsage]

    enum CodingKeys: String, CodingKey {
        case toolUsage = "tool_usage"
    }
}

// MARK: - The tool-usage query, over the generic bridge

extension AdeleCore {
    /// What each tool cost one conversation (desktop-assistant#599).
    ///
    /// An empty array is a real answer, not a failure: it means the conversation
    /// called no tools. A caller renders that as an empty state rather than an
    /// error.
    @MainActor
    public func toolUsage(conversationID: String) async throws -> [ToolUsage] {
        let data = try await sendCommand(
            AdeleCommand.getToolUsage(conversationID: conversationID))
        return try JSONDecoder().decode(
            CommandResultEnvelope<ToolUsageResultPayload>.self, from: data
        ).result?.toolUsage ?? []
    }
}
