import Foundation

// MARK: - Connection create/update/delete (issue #11)
//
// Reuses the read side (`listConnections()` / `ConnectionView` in
// Management.swift). These mutating commands reply with `CommandResult::Ack`;
// `sendCommand` throws on a `command_result` error, so success is simply "did
// not throw" — we discard the (empty) payload.

extension AdeleCore {
    /// Create a new named connection. `id` must be a valid slug and must not
    /// already exist (the daemon rejects duplicates). Throws `CommandError` on
    /// failure.
    @MainActor
    public func createConnection(id: String, config: ConnectionConfigInput) async throws {
        _ = try await sendCommand(AdeleCommand.createConnection(id: id, config: config))
    }

    /// Replace an existing connection's config in-place. Throws on failure
    /// (e.g. unknown id).
    @MainActor
    public func updateConnection(id: String, config: ConnectionConfigInput) async throws {
        _ = try await sendCommand(AdeleCommand.updateConnection(id: id, config: config))
    }

    /// Delete a named connection. When `force` is false the daemon refuses if
    /// any purpose still references it; `force: true` reassigns those purposes
    /// to `interactive`. Throws on failure.
    @MainActor
    public func deleteConnection(id: String, force: Bool = false) async throws {
        _ = try await sendCommand(AdeleCommand.deleteConnection(id: id, force: force))
    }

    /// Store (or clear) a connection's raw credential in the daemon's secret
    /// store — never in daemon.toml, never echoed back. Empty `credential`
    /// clears it. For Bedrock the value is
    /// `ACCESS_KEY_ID:SECRET_ACCESS_KEY[:SESSION_TOKEN]`; for api-key connectors
    /// the raw key. Lets hosted/end-user setups supply credentials directly
    /// without requiring env vars or `~/.aws/config`. Throws on failure.
    @MainActor
    public func setConnectionSecret(id: String, credential: String) async throws {
        _ = try await sendCommand(AdeleCommand.setConnectionSecret(id: id, credential: credential))
    }
}
