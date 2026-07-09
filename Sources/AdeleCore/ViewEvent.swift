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

/// A model's capabilities (only the fields the UI uses; extras are ignored).
public struct ModelCapabilities: Decodable, Hashable, Sendable {
    public let reasoning: Bool

    enum CodingKeys: String, CodingKey { case reasoning }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reasoning = (try? c.decode(Bool.self, forKey: .reasoning)) ?? false
    }
    public init(reasoning: Bool) { self.reasoning = reasoning }
}

/// One model offered by a connection.
public struct ModelInfo: Decodable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let contextLimit: UInt64?
    public let capabilities: ModelCapabilities

    enum CodingKeys: String, CodingKey {
        case id, capabilities
        case displayName = "display_name"
        case contextLimit = "context_limit"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        contextLimit = try c.decodeIfPresent(UInt64.self, forKey: .contextLimit)
        capabilities = (try? c.decode(ModelCapabilities.self, forKey: .capabilities))
            ?? ModelCapabilities(reasoning: false)
    }
}

/// A model available for selection, grouped under its connection.
public struct ModelListing: Decodable, Identifiable, Hashable, Sendable {
    public let connectionId: String
    public let connectionLabel: String
    public let model: ModelInfo

    public var id: String { "\(connectionId)/\(model.id)" }

    enum CodingKeys: String, CodingKey {
        case model
        case connectionId = "connection_id"
        case connectionLabel = "connection_label"
    }
}

/// The per-conversation model selection (with optional effort hint).
public struct ModelSelection: Decodable, Hashable, Sendable {
    public let connectionId: String
    public let modelId: String
    /// "low" | "medium" | "high" | nil.
    public let effort: String?

    enum CodingKeys: String, CodingKey {
        case effort
        case connectionId = "connection_id"
        case modelId = "model_id"
    }
}

/// The resolved interactive-purpose default model (picker fallback).
public struct SelectedModel: Decodable, Hashable, Sendable {
    public let connectionId: String
    public let modelId: String

    enum CodingKeys: String, CodingKey {
        case connectionId = "connection_id"
        case modelId = "model_id"
    }
}

/// A background task (only the fields the UI uses; `kind`/`parent`/`children`
/// are not decoded).
public struct TaskView: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    /// "pending" | "running" | "completed" | "failed" | "cancelled".
    public var status: String
    public let title: String
    public var progressHint: String?
    public let lastError: String?
    public let startedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, status, title
        case progressHint = "progress_hint"
        case lastError = "last_error"
        case startedAt = "started_at"
    }

    public var isActive: Bool { status == "pending" || status == "running" }
}

/// A single background-task log line.
public struct TaskLogEntry: Decodable, Identifiable, Hashable, Sendable {
    public let seq: UInt64
    public let timestamp: Int64
    /// "trace" | "debug" | "info" | "warn" | "error".
    public let level: String
    public let message: String

    public var id: UInt64 { seq }

    enum CodingKeys: String, CodingKey { case seq, timestamp, level, message }
}

/// A scratchpad note (per-conversation working memory the assistant maintains).
public struct ScratchpadNote: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let key: String
    public let content: String
    public let noteType: String
    public let sequence: Int32?
    public let done: Bool
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, key, content, sequence, done
        case noteType = "note_type"
        case updatedAt = "updated_at"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        key = try c.decode(String.self, forKey: .key)
        content = try c.decode(String.self, forKey: .content)
        noteType = (try? c.decode(String.self, forKey: .noteType)) ?? "note"
        sequence = try c.decodeIfPresent(Int32.self, forKey: .sequence)
        done = (try? c.decode(Bool.self, forKey: .done)) ?? false
        updatedAt = try c.decode(String.self, forKey: .updatedAt)
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
    case models([ModelListing])
    case modelSelection(ModelSelection?)
    case defaultModel(SelectedModel?)
    case modelPickerVisible(Bool)
    case tasksReplaceAll([TaskView])
    case taskStarted(TaskView)
    case taskProgress(id: String, progressHint: String?)
    case taskLogAppended(id: String, entry: TaskLogEntry)
    case taskCompleted(id: String)
    case taskLogs(id: String, entries: [TaskLogEntry])
    case scratchpad([ScratchpadNote])
    case toast(text: String)
    case inlineNote(text: String)
    /// Any event not yet typed (scratchpad, voice, …).
    case unknown(type: String)

    private enum Keys: String, CodingKey {
        case type, label, message, text, value, items, detail, usage, content
        case selection, model, task, id, entry, entries, notes
        case progressHint = "progress_hint"
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
        case "models":
            self = .models(try c.decode([ModelListing].self, forKey: .items))
        case "model_selection":
            self = .modelSelection(try c.decodeIfPresent(ModelSelection.self, forKey: .selection))
        case "default_model":
            self = .defaultModel(try c.decodeIfPresent(SelectedModel.self, forKey: .model))
        case "model_picker_visible":
            self = .modelPickerVisible(try c.decode(Bool.self, forKey: .value))
        case "tasks_replace_all":
            self = .tasksReplaceAll(try c.decode([TaskView].self, forKey: .items))
        case "task_started":
            self = .taskStarted(try c.decode(TaskView.self, forKey: .task))
        case "task_progress":
            self = .taskProgress(
                id: try c.decode(String.self, forKey: .id),
                progressHint: try c.decodeIfPresent(String.self, forKey: .progressHint)
            )
        case "task_log_appended":
            self = .taskLogAppended(
                id: try c.decode(String.self, forKey: .id),
                entry: try c.decode(TaskLogEntry.self, forKey: .entry)
            )
        case "task_completed":
            self = .taskCompleted(id: try c.decode(String.self, forKey: .id))
        case "task_logs":
            self = .taskLogs(
                id: try c.decode(String.self, forKey: .id),
                entries: try c.decode([TaskLogEntry].self, forKey: .entries)
            )
        case "scratchpad":
            self = .scratchpad(try c.decode([ScratchpadNote].self, forKey: .notes))
        case "toast":
            self = .toast(text: try c.decode(String.self, forKey: .text))
        case "inline_note":
            self = .inlineNote(text: try c.decode(String.self, forKey: .text))
        default:
            self = .unknown(type: type)
        }
    }
}
