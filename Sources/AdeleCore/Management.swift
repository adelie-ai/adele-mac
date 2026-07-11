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
