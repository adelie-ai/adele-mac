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
        let data = try await sendCommand(AdeleCommand.listConnections)
        let envelope = try JSONDecoder().decode(CommandResultEnvelope<ConnectionsPayload>.self, from: data)
        return envelope.result?.connections ?? []
    }

    @MainActor
    public func getPurposes() async throws -> PurposesView {
        let data = try await sendCommand(AdeleCommand.getPurposes)
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
        _ = try await sendCommand(AdeleCommand.setPurpose(
            purpose, connection: connection, model: model, effort: effort
        ))  // CommandResult::Ack, or throws
    }
}

// MARK: - Knowledge base

extension AdeleCore {
    private struct KnowledgeEntriesPayload: Decodable { let knowledge_entries: [KnowledgeEntry] }
    private struct KnowledgeWrittenPayload: Decodable { let knowledge_entry_written: KnowledgeEntry }

    @MainActor
    public func listKnowledgeEntries(limit: Int = 100, offset: Int = 0) async throws -> [KnowledgeEntry] {
        let data = try await sendCommand(AdeleCommand.listKnowledge(limit: limit, offset: offset))
        return try JSONDecoder().decode(CommandResultEnvelope<KnowledgeEntriesPayload>.self, from: data)
            .result?.knowledge_entries ?? []
    }

    @MainActor
    public func searchKnowledgeEntries(_ query: String, limit: Int = 100) async throws -> [KnowledgeEntry] {
        let data = try await sendCommand(AdeleCommand.searchKnowledge(query: query, limit: limit))
        return try JSONDecoder().decode(CommandResultEnvelope<KnowledgeEntriesPayload>.self, from: data)
            .result?.knowledge_entries ?? []
    }

    @MainActor
    @discardableResult
    public func createKnowledgeEntry(content: String, tags: [String]) async throws -> KnowledgeEntry {
        let data = try await sendCommand(AdeleCommand.createKnowledge(content: content, tags: tags))
        guard let entry = try JSONDecoder().decode(CommandResultEnvelope<KnowledgeWrittenPayload>.self, from: data)
            .result?.knowledge_entry_written else { throw CommandError.failed("no entry returned") }
        return entry
    }

    @MainActor
    @discardableResult
    public func updateKnowledgeEntry(id: String, content: String, tags: [String]) async throws -> KnowledgeEntry {
        let data = try await sendCommand(AdeleCommand.updateKnowledge(id: id, content: content, tags: tags))
        guard let entry = try JSONDecoder().decode(CommandResultEnvelope<KnowledgeWrittenPayload>.self, from: data)
            .result?.knowledge_entry_written else { throw CommandError.failed("no entry returned") }
        return entry
    }

    @MainActor
    public func deleteKnowledgeEntry(id: String) async throws {
        _ = try await sendCommand(AdeleCommand.deleteKnowledge(id: id))
    }
}
