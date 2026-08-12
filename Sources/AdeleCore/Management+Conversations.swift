import Foundation

// MARK: - Conversation management (rename / archive / unarchive)
//
// These mutating commands reply with `CommandResult::Ack`; `sendCommand` throws
// on a `command_result` error, so success is simply "did not throw" — we discard
// the (empty) payload. The sidebar context menu drives these; `ConversationSummary`
// already carries `archived` to pick between archive/unarchive.

extension AdeleCore {
    /// Rename a conversation's title. Throws `CommandError` on failure
    /// (e.g. unknown id).
    @MainActor
    public func renameConversation(id: String, title: String) async throws {
        _ = try await sendCommand(AdeleCommand.renameConversation(id: id, title: title))
    }

    /// Archive a conversation (hide it from the active list). Throws on failure.
    ///
    /// The daemon answers this with an acknowledgement and nothing else, so it
    /// refreshes no list on its own. A caller that wants the sidebar to follow
    /// the change uses ``AdeleCore/archiveConversation(_:)`` instead - the
    /// core's typed entry point, which re-reads the inventory after the change
    /// lands (adele-mac#46). This stays for a caller that wants the raw command
    /// and will refresh itself.
    @MainActor
    public func archiveConversation(id: String) async throws {
        _ = try await sendCommand(AdeleCommand.archiveConversation(id: id))
    }

    /// Restore a previously archived conversation to the active list. Throws on
    /// failure. The sibling of the archive command above, with the same caveat:
    /// it refreshes nothing. Prefer ``AdeleCore/unarchiveConversation(_:)``.
    @MainActor
    public func unarchiveConversation(id: String) async throws {
        _ = try await sendCommand(AdeleCommand.unarchiveConversation(id: id))
    }
}
