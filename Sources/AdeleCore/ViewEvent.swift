import Foundation

// The typed mirror of the Rust FFI's view-event schema (client-ui-ffi's
// view_event.rs): `{"type": "<snake_case>", ...fields}`. The reducer already
// decided what changed, so these are deltas the UI applies verbatim — there is
// no controller logic on the Swift side.
//
// Phase 1 models the chat/conversation/lifecycle events; the remaining variants
// (models, tasks, scratchpad, voice) decode to `.unknown` so a forward-compatible
// core never breaks decoding. They gain typed cases as later phases wire them up.

/// A conversation row for the sidebar.
public struct ConversationSummary: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let messageCount: UInt32
    public let archived: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, archived
        case messageCount = "message_count"
    }
}

/// A single message in a transcript.
public struct ChatMessage: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let role: String
    public let content: String
}

/// The open conversation (already debug-filtered by the reducer). `model_selection`
/// is intentionally not modeled in Phase 1.
public struct ConversationDetail: Decodable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let messages: [ChatMessage]
}

/// Context-window fill readout. All formatting (`readout`, `level`) is computed
/// in Rust so the UI never reimplements it.
public struct ContextUsage: Decodable, Hashable, Sendable {
    public let usedTokens: UInt64
    public let budgetTokens: UInt64
    public let compactionActive: Bool
    public let fraction: Double
    /// "green" | "amber" | "red".
    public let level: String
    /// Pre-formatted, e.g. "12k / 32k (38%)".
    public let readout: String

    enum CodingKeys: String, CodingKey {
        case fraction, level, readout
        case usedTokens = "used_tokens"
        case budgetTokens = "budget_tokens"
        case compactionActive = "compaction_active"
    }
}

/// One pushed view-update from the core.
public enum ViewEvent: Decodable, Sendable {
    case connected(label: String)
    case connectError(message: String)
    case clientCleared
    case status(text: String)
    case sendSensitive(Bool)
    case conversations([ConversationSummary])
    case loadConversation(ConversationDetail)
    case clearChat
    case chatStatus(text: String)
    case clearChatStatus
    case contextUsage(ContextUsage?)
    case addUserMessage(content: String)
    case chunk(text: String)
    case complete(text: String)
    case toast(text: String)
    case inlineNote(text: String)
    /// Any event not yet typed (models, tasks, scratchpad, voice, …).
    case unknown(type: String)

    private enum Keys: String, CodingKey {
        case type, label, message, text, value, items, detail, usage, content
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "connected":
            self = .connected(label: try c.decode(String.self, forKey: .label))
        case "connect_error":
            self = .connectError(message: try c.decode(String.self, forKey: .message))
        case "client_cleared":
            self = .clientCleared
        case "status":
            self = .status(text: try c.decode(String.self, forKey: .text))
        case "send_sensitive":
            self = .sendSensitive(try c.decode(Bool.self, forKey: .value))
        case "conversations":
            self = .conversations(try c.decode([ConversationSummary].self, forKey: .items))
        case "load_conversation":
            self = .loadConversation(try c.decode(ConversationDetail.self, forKey: .detail))
        case "clear_chat":
            self = .clearChat
        case "chat_status":
            self = .chatStatus(text: try c.decode(String.self, forKey: .text))
        case "clear_chat_status":
            self = .clearChatStatus
        case "context_usage":
            self = .contextUsage(try c.decodeIfPresent(ContextUsage.self, forKey: .usage))
        case "add_user_message":
            self = .addUserMessage(content: try c.decode(String.self, forKey: .content))
        case "chunk":
            self = .chunk(text: try c.decode(String.self, forKey: .text))
        case "complete":
            self = .complete(text: try c.decode(String.self, forKey: .text))
        case "toast":
            self = .toast(text: try c.decode(String.self, forKey: .text))
        case "inline_note":
            self = .inlineNote(text: try c.decode(String.self, forKey: .text))
        default:
            self = .unknown(type: type)
        }
    }
}
