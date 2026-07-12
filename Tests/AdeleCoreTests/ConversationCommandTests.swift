import Testing
import Foundation
@testable import AdeleCore

/// Spec: conversation-management builders produce the exact `api::Command` wire
/// shape (externally tagged, snake_case). All three reply `CommandResult::Ack`.
/// Assertions parse the JSON so they're robust to key ordering.
@Suite struct ConversationCommandTests {
    private func object(_ json: String) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try #require(value as? [String: Any])
    }

    @Test func renameConversationShape() throws {
        let json = AdeleCommand.renameConversation(id: "conv-1", title: "Trip planning")
        let payload = try #require((try object(json))["rename_conversation"] as? [String: Any])
        #expect(payload["id"] as? String == "conv-1")
        #expect(payload["title"] as? String == "Trip planning")
        #expect(payload.count == 2, "rename_conversation carries exactly id + title")
    }

    @Test func archiveConversationShape() throws {
        let json = AdeleCommand.archiveConversation(id: "conv-2")
        let payload = try #require((try object(json))["archive_conversation"] as? [String: Any])
        #expect(payload["id"] as? String == "conv-2")
        #expect(payload.count == 1, "archive_conversation carries only id")
    }

    @Test func unarchiveConversationShape() throws {
        let json = AdeleCommand.unarchiveConversation(id: "conv-3")
        let payload = try #require((try object(json))["unarchive_conversation"] as? [String: Any])
        #expect(payload["id"] as? String == "conv-3")
        #expect(payload.count == 1, "unarchive_conversation carries only id")
    }
}
