import CAdeleCore
import Foundation

// Administering the client-run MCP population: the servers this Mac runs itself,
// defined in the machine-wide `client-mcp.toml`.
//
// The core owns that file. Every Adele client on the machine reads the same one,
// so a second parser or writer here would be a correctness hazard for all of
// them; Swift asks the core for an edit and renders whatever the core reads back.
// This file holds the payload builder, the three write calls, and the pure form
// logic the panel needs (location, footer wording, name notes).
//
// Not here: the daemon fleet, which is administered over the daemon command
// channel (`Management+Mcp.swift`), and the built-in opt-out, which the core
// writes through `setMcpBuiltinDisabled`.

/// The add form's payload for a client-run server, in the shape the core reads.
///
/// The core refuses a field it does not know, rather than ignoring it, so this
/// type is the contract: it carries every field the core reads and nothing else.
/// A client-run server is always stdio - there is no client-side secret store to
/// authenticate an HTTP endpoint with - so no transport field exists to set.
private struct McpClientServerPayload: Encodable {
    let name: String
    let command: String
    let args: [String]
    /// Omitted when the server namespaces nothing. Never an empty string, which
    /// would namespace its tools under "".
    let namespace: String?
    let enabled: Bool
}

/// Build the JSON the core's `adele_core_upsert_mcp_client_server` takes.
///
/// Blank input is normalized here rather than at the core: a name or command of
/// spaces is refused by the core, and an empty namespace becomes "no namespace".
public func mcpClientServerJSON(
    name: String,
    command: String,
    args: [String],
    namespace: String?,
    enabled: Bool
) -> String {
    let trimmedNamespace = namespace?.trimmingCharacters(in: .whitespaces)
    let payload = McpClientServerPayload(
        name: name.trimmingCharacters(in: .whitespaces),
        command: command.trimmingCharacters(in: .whitespaces),
        args: args,
        namespace: (trimmedNamespace?.isEmpty ?? true) ? nil : trimmedNamespace,
        enabled: enabled
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(payload), let json = String(data: data, encoding: .utf8)
    else {
        // Unreachable for a payload of plain strings and bools; an empty object
        // makes the core refuse the write by name rather than silently writing a
        // server built from nothing.
        return "{}"
    }
    return json
}

/// Whether a client-run row's enable control reads on.
///
/// The core lists every server the machine defines, and reports `disabled` for
/// one this surface does not host - so a switched-off server stays visible and
/// can be switched back on.
public func mcpClientRowIsOn(_ row: McpServerRow) -> Bool {
    row.status != "disabled"
}

/// Where a newly added MCP server runs.
///
/// The daemon may be on another host, so the two are not interchangeable: a
/// server that must reach this machine's files, network or devices only works
/// when this client runs it.
public enum McpAddLocation: String, Sendable, Hashable, CaseIterable {
    /// Run by the daemon, through its `AddMcpServer` command.
    case daemon
    /// Run by this client, from the machine-wide `client-mcp.toml`.
    case client

    public var label: String {
        switch self {
        case .daemon: return "Daemon"
        case .client: return "This Mac"
        }
    }
}

/// Whether the add form can submit for `location` right now.
///
/// A daemon server is created over the daemon command channel, so it needs a
/// connection. A client-run server is written to a local file, so it does not.
public func mcpCanAdd(location: McpAddLocation, connected: Bool) -> Bool {
    switch location {
    case .daemon: return connected
    case .client: return true
    }
}

/// What the add form says about the selected location: who will run the server,
/// and when it starts.
public func mcpAddFooter(location: McpAddLocation, connected: Bool) -> String {
    switch location {
    case .daemon:
        return connected
            ? "The daemon runs this server, on whichever host the daemon is on."
            : "Connect to add a server the daemon runs."
    case .client:
        return """
            This Mac runs this server, so it can reach local files and devices. \
            It starts on the next connection.
            """
    }
}

/// A note about the name being typed, when it means something beyond a new
/// server. `nil` when the name is fresh.
///
/// None of these is an error. A client-run server that shares a built-in's name
/// overrides it, which is how a person replaces a compiled-in server with their
/// own; a client-run name that already exists edits that definition; and the
/// daemon and client populations are separate, so a name may sit in both.
public func mcpAddNameNote(
    name: String,
    location: McpAddLocation,
    rows: [McpServerRow]
) -> String? {
    let trimmed = name.trimmingCharacters(in: .whitespaces).lowercased()
    guard !trimmed.isEmpty else { return nil }
    guard location == .client else { return nil }

    let clientRows = rows.filter { $0.runner == .client && $0.name.lowercased() == trimmed }
    if clientRows.contains(where: { $0.kind == .builtIn }) {
        return "This name overrides the built-in server of the same name."
    }
    if !clientRows.isEmpty {
        return "A server of this name already runs here. Adding replaces it."
    }
    return nil
}

// MARK: - The write calls

extension AdeleCore {
    /// Add one client-run MCP server to the machine-wide `client-mcp.toml`, or
    /// edit the one of the same name, returning the refreshed inventory once the
    /// core has written it.
    ///
    /// `enabled` sets both grains at once: the definition's own switch and this
    /// client's surface membership. An edit preserves what this form cannot
    /// carry - environment variables, secret references, the server description.
    ///
    /// The change takes effect on the next connect (a running MCP host is fixed
    /// at start), but the returned inventory already reflects it, so the panel
    /// shows the pending state rather than looking unchanged. A refused write
    /// comes back as a `toast` event plus the inventory that is still on disk.
    @MainActor
    @discardableResult
    public func upsertMcpClientServer(
        name: String,
        command: String,
        args: [String],
        namespace: String?,
        enabled: Bool = true
    ) async -> [McpClientServer] {
        let json = mcpClientServerJSON(
            name: name, command: command, args: args, namespace: namespace, enabled: enabled
        )
        return await withRefreshedClientServers { adele_core_upsert_mcp_client_server($0, json) }
    }

    /// Delete one client-run MCP server definition, returning the refreshed
    /// inventory.
    ///
    /// The definition is machine-wide, so this removes it for **every** client on
    /// this Mac. To stop running it here while other clients keep it, use
    /// ``setMcpClientServerEnabled(name:enabled:)`` instead.
    @MainActor
    @discardableResult
    public func removeMcpClientServer(name: String) async -> [McpClientServer] {
        await withRefreshedClientServers { adele_core_remove_mcp_client_server($0, name) }
    }

    /// Turn one client-run MCP server on or off **for this client**, returning
    /// the refreshed inventory.
    ///
    /// Turning it off drops it from this client's selection only, so another
    /// client on the same Mac that lists it keeps running it. The definition
    /// stays, so the row remains visible and can be turned back on.
    @MainActor
    @discardableResult
    public func setMcpClientServerEnabled(
        name: String, enabled: Bool
    ) async -> [McpClientServer] {
        await withRefreshedClientServers {
            adele_core_set_mcp_client_server_enabled($0, name, enabled)
        }
    }
}
