import Foundation

/// Pure builders for the `api::Command` wire format (externally-tagged,
/// snake_case: unit variants are bare JSON strings, struct variants are
/// `{"variant_name": {fields}}`). Kept separate from the transport so the exact
/// wire shape is unit-testable without a live daemon — the daemon parses any key
/// order, but tests assert the parsed structure.
public enum AdeleCommand {
    /// Encode an `Encodable` command wrapper to a JSON string (sorted keys for
    /// deterministic test output; the daemon is order-insensitive).
    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Unit commands (bare JSON strings)

    public static let listConnections = "\"list_connections\""
    public static let getPurposes = "\"get_purposes\""
    public static let getConfig = "\"get_config\""
    public static let listMcpServers = "\"list_mcp_servers\""

    // MARK: Purposes

    public static func setPurpose(
        _ purpose: String,
        connection: String,
        model: String,
        effort: String? = nil
    ) -> String {
        struct Config: Encodable {
            let connection: String
            let model: String
            let effort: String?
        }
        struct Payload: Encodable { let purpose: String; let config: Config }
        struct Cmd: Encodable { let set_purpose: Payload }
        return encode(Cmd(set_purpose: Payload(
            purpose: purpose,
            config: Config(connection: connection, model: model, effort: effort)
        )))
    }

    // MARK: Knowledge base

    public static func listKnowledge(limit: Int, offset: Int) -> String {
        struct Cmd: Encodable {
            struct P: Encodable { let limit: Int; let offset: Int }
            let list_knowledge_entries: P
        }
        return encode(Cmd(list_knowledge_entries: .init(limit: limit, offset: offset)))
    }

    public static func searchKnowledge(query: String, limit: Int) -> String {
        struct Cmd: Encodable {
            struct P: Encodable { let query: String; let limit: Int }
            let search_knowledge_entries: P
        }
        return encode(Cmd(search_knowledge_entries: .init(query: query, limit: limit)))
    }

    public static func createKnowledge(content: String, tags: [String]) -> String {
        struct Cmd: Encodable {
            struct P: Encodable { let content: String; let tags: [String] }
            let create_knowledge_entry: P
        }
        return encode(Cmd(create_knowledge_entry: .init(content: content, tags: tags)))
    }

    public static func updateKnowledge(id: String, content: String, tags: [String]) -> String {
        struct Cmd: Encodable {
            struct P: Encodable { let id: String; let content: String; let tags: [String] }
            let update_knowledge_entry: P
        }
        return encode(Cmd(update_knowledge_entry: .init(id: id, content: content, tags: tags)))
    }

    public static func deleteKnowledge(id: String) -> String {
        struct Cmd: Encodable {
            struct P: Encodable { let id: String }
            let delete_knowledge_entry: P
        }
        return encode(Cmd(delete_knowledge_entry: .init(id: id)))
    }
}
