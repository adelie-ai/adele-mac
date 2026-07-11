import Testing
import Foundation
@testable import AdeleCore

/// Spec: `AdeleCommand` builders produce the exact `api::Command` wire shape
/// (externally tagged, snake_case). Assertions parse the JSON and check
/// structure so they're robust to key ordering (the daemon is order-insensitive).
@Suite struct CommandBuilderTests {
    private func object(_ json: String) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try #require(value as? [String: Any])
    }

    @Test func unitCommandsAreBareStrings() {
        #expect(AdeleCommand.listConnections == "\"list_connections\"")
        #expect(AdeleCommand.getPurposes == "\"get_purposes\"")
        #expect(AdeleCommand.getConfig == "\"get_config\"")
        #expect(AdeleCommand.listMcpServers == "\"list_mcp_servers\"")
    }

    @Test func setPurposeOmitsEffortWhenNil() throws {
        let json = AdeleCommand.setPurpose("interactive", connection: "bedrock", model: "us.anthropic.claude-x")
        let payload = try #require((try object(json))["set_purpose"] as? [String: Any])
        #expect(payload["purpose"] as? String == "interactive")
        let config = try #require(payload["config"] as? [String: Any])
        #expect(config["connection"] as? String == "bedrock")
        #expect(config["model"] as? String == "us.anthropic.claude-x")
        #expect(config["effort"] == nil, "effort must be omitted when nil (PurposeConfigView skips None)")
    }

    @Test func setPurposeIncludesEffort() throws {
        let json = AdeleCommand.setPurpose("interactive", connection: "c", model: "m", effort: "low")
        let payload = try #require((try object(json))["set_purpose"] as? [String: Any])
        let config = try #require(payload["config"] as? [String: Any])
        #expect(config["effort"] as? String == "low")
    }

    @Test func knowledgeListShape() throws {
        let p = try #require((try object(AdeleCommand.listKnowledge(limit: 25, offset: 10)))["list_knowledge_entries"] as? [String: Any])
        #expect(p["limit"] as? Int == 25)
        #expect(p["offset"] as? Int == 10)
    }

    @Test func knowledgeSearchShape() throws {
        let p = try #require((try object(AdeleCommand.searchKnowledge(query: "tls", limit: 5)))["search_knowledge_entries"] as? [String: Any])
        #expect(p["query"] as? String == "tls")
        #expect(p["limit"] as? Int == 5)
    }

    @Test func knowledgeCreateUpdateDeleteShapes() throws {
        let cp = try #require((try object(AdeleCommand.createKnowledge(content: "note", tags: ["a", "b"])))["create_knowledge_entry"] as? [String: Any])
        #expect(cp["content"] as? String == "note")
        #expect(cp["tags"] as? [String] == ["a", "b"])

        let up = try #require((try object(AdeleCommand.updateKnowledge(id: "k1", content: "x", tags: [])))["update_knowledge_entry"] as? [String: Any])
        #expect(up["id"] as? String == "k1")

        let dp = try #require((try object(AdeleCommand.deleteKnowledge(id: "k1")))["delete_knowledge_entry"] as? [String: Any])
        #expect(dp["id"] as? String == "k1")
    }
}
