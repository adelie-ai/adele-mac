import Foundation

// MARK: - Conversation-management command builders
//
// Pure builders for the conversation lifecycle commands in `api::Command`
// (externally tagged, snake_case). Each reply is `CommandResult::Ack`.

extension AdeleCommand {
    /// `{"rename_conversation":{"id":"<id>","title":"<title>"}}`
    public static func renameConversation(id: String, title: String) -> String {
        struct Cmd: Encodable {
            struct P: Encodable { let id: String; let title: String }
            let rename_conversation: P
        }
        return encode(Cmd(rename_conversation: .init(id: id, title: title)))
    }

    /// `{"archive_conversation":{"id":"<id>"}}`
    public static func archiveConversation(id: String) -> String {
        struct Cmd: Encodable {
            struct P: Encodable { let id: String }
            let archive_conversation: P
        }
        return encode(Cmd(archive_conversation: .init(id: id)))
    }

    /// `{"unarchive_conversation":{"id":"<id>"}}`
    public static func unarchiveConversation(id: String) -> String {
        struct Cmd: Encodable {
            struct P: Encodable { let id: String }
            let unarchive_conversation: P
        }
        return encode(Cmd(unarchive_conversation: .init(id: id)))
    }
}
