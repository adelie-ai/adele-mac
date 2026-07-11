import Foundation

/// Error from a management command (`send_command`).
public enum CommandError: Error, CustomStringConvertible {
    case failed(String)
    public var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

/// Minimal decode of a `command_result` event to correlate + branch on success.
struct CommandResultHead: Decodable {
    let type: String
    let requestID: String
    let ok: Bool
    let error: String?

    enum CodingKeys: String, CodingKey {
        case type, ok, error
        case requestID = "request_id"
    }
}

/// Typed decode of a `command_result` event's `result` payload.
struct CommandResultEnvelope<T: Decodable>: Decodable {
    let result: T?
}

// MARK: - Management view types (mirror desktop-assistant api-model)

public struct ConnectionAvailability: Decodable, Hashable, Sendable {
    /// "ok" | "unavailable".
    public let status: String
    public let reason: String?
    public var isOk: Bool { status == "ok" }
}

public struct ConnectionView: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let connectorType: String
    public let displayLabel: String
    public let availability: ConnectionAvailability
    public let hasCredentials: Bool

    enum CodingKeys: String, CodingKey {
        case id, availability
        case connectorType = "connector_type"
        case displayLabel = "display_label"
        case hasCredentials = "has_credentials"
    }
}

public struct PurposeConfigView: Decodable, Hashable, Sendable {
    /// A connection id, or the literal "primary" (inherit from interactive).
    public let connection: String
    /// A model id, or the literal "primary".
    public let model: String
    public let effort: String?
}

public struct PurposesView: Decodable, Hashable, Sendable {
    public var interactive: PurposeConfigView?
    public var dreaming: PurposeConfigView?
    public var consolidation: PurposeConfigView?
    public var embedding: PurposeConfigView?
    public var titling: PurposeConfigView?
    public init() {}
}

/// A knowledge-base entry (metadata omitted — the UI doesn't surface it).
public struct KnowledgeEntry: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public var content: String
    public var tags: [String]
    public let createdAt: String
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, content, tags
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Typed management commands over the generic bridge

extension AdeleCore {
    private struct ConnectionsPayload: Decodable { let connections: [ConnectionView] }
    private struct PurposesPayload: Decodable { let purposes: PurposesView }

    /// The five configurable purposes (matches api-model `PurposeKind`).
    public static let purposeKinds = ["interactive", "dreaming", "consolidation", "embedding", "titling"]

    @MainActor
    public func listConnections() async throws -> [ConnectionView] {
        // Unit command variants serialize as a bare JSON string.
        let data = try await sendCommand("\"list_connections\"")
        let envelope = try JSONDecoder().decode(CommandResultEnvelope<ConnectionsPayload>.self, from: data)
        return envelope.result?.connections ?? []
    }

    @MainActor
    public func getPurposes() async throws -> PurposesView {
        let data = try await sendCommand("\"get_purposes\"")
        let envelope = try JSONDecoder().decode(CommandResultEnvelope<PurposesPayload>.self, from: data)
        return envelope.result?.purposes ?? PurposesView()
    }

    /// Assign a purpose to a connection+model (effort optional). `purpose` is one
    /// of `purposeKinds`; "primary" in connection/model inherits from interactive.
    @MainActor
    public func setPurpose(
        _ purpose: String,
        connection: String,
        model: String,
        effort: String? = nil
    ) async throws {
        struct Config: Encodable {
            let connection: String
            let model: String
            let effort: String?
        }
        struct Payload: Encodable {
            let purpose: String
            let config: Config
        }
        struct Cmd: Encodable {
            let set_purpose: Payload  // externally-tagged Command::SetPurpose
        }
        let command = Cmd(set_purpose: Payload(
            purpose: purpose,
            config: Config(connection: connection, model: model, effort: effort)
        ))
        let json = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
        _ = try await sendCommand(json)  // CommandResult::Ack, or throws
    }
}

// MARK: - Knowledge base

extension AdeleCore {
    private struct KnowledgeEntriesPayload: Decodable { let knowledge_entries: [KnowledgeEntry] }
    private struct KnowledgeWrittenPayload: Decodable { let knowledge_entry_written: KnowledgeEntry }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    @MainActor
    public func listKnowledgeEntries(limit: Int = 100, offset: Int = 0) async throws -> [KnowledgeEntry] {
        struct Cmd: Encodable {
            struct P: Encodable { let limit: Int; let offset: Int }
            let list_knowledge_entries: P
        }
        let data = try await sendCommand(try encode(Cmd(list_knowledge_entries: .init(limit: limit, offset: offset))))
        return try JSONDecoder().decode(CommandResultEnvelope<KnowledgeEntriesPayload>.self, from: data)
            .result?.knowledge_entries ?? []
    }

    @MainActor
    public func searchKnowledgeEntries(_ query: String, limit: Int = 100) async throws -> [KnowledgeEntry] {
        struct Cmd: Encodable {
            struct P: Encodable { let query: String; let limit: Int }
            let search_knowledge_entries: P
        }
        let data = try await sendCommand(try encode(Cmd(search_knowledge_entries: .init(query: query, limit: limit))))
        return try JSONDecoder().decode(CommandResultEnvelope<KnowledgeEntriesPayload>.self, from: data)
            .result?.knowledge_entries ?? []
    }

    @MainActor
    @discardableResult
    public func createKnowledgeEntry(content: String, tags: [String]) async throws -> KnowledgeEntry {
        struct Cmd: Encodable {
            struct P: Encodable { let content: String; let tags: [String] }
            let create_knowledge_entry: P
        }
        let data = try await sendCommand(try encode(Cmd(create_knowledge_entry: .init(content: content, tags: tags))))
        guard let entry = try JSONDecoder().decode(CommandResultEnvelope<KnowledgeWrittenPayload>.self, from: data)
            .result?.knowledge_entry_written else { throw CommandError.failed("no entry returned") }
        return entry
    }

    @MainActor
    @discardableResult
    public func updateKnowledgeEntry(id: String, content: String, tags: [String]) async throws -> KnowledgeEntry {
        struct Cmd: Encodable {
            struct P: Encodable { let id: String; let content: String; let tags: [String] }
            let update_knowledge_entry: P
        }
        let data = try await sendCommand(try encode(Cmd(update_knowledge_entry: .init(id: id, content: content, tags: tags))))
        guard let entry = try JSONDecoder().decode(CommandResultEnvelope<KnowledgeWrittenPayload>.self, from: data)
            .result?.knowledge_entry_written else { throw CommandError.failed("no entry returned") }
        return entry
    }

    @MainActor
    public func deleteKnowledgeEntry(id: String) async throws {
        struct Cmd: Encodable {
            struct P: Encodable { let id: String }
            let delete_knowledge_entry: P
        }
        _ = try await sendCommand(try encode(Cmd(delete_knowledge_entry: .init(id: id))))
    }
}
