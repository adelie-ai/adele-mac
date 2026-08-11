import Foundation
import Testing

@testable import AdeleCore

/// Spec for administering the **client-run** MCP population: the payload the
/// core's `adele_core_upsert_mcp_client_server` takes, the controls a client-run
/// row offers, and the wording the add form shows for each location.
///
/// The writes themselves land in the machine-wide `client-mcp.toml`, which the
/// Rust core owns; these cases cover the pure Swift side of that seam, so they
/// need no core and no file.
@Suite struct ClientMcpWriteTests {
    // MARK: The upsert payload

    /// Every field the core reads, spelled the way it reads them. The core
    /// refuses an unknown field, so a misspelling here fails the whole write.
    @Test func upsertPayloadCarriesEveryFieldTheCoreReads() throws {
        let json = mcpClientServerJSON(
            name: "notes",
            command: "notes-mcp",
            args: ["--stdio", "--quiet"],
            namespace: "notes",
            enabled: true
        )
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        #expect(decoded["name"] as? String == "notes")
        #expect(decoded["command"] as? String == "notes-mcp")
        #expect(decoded["args"] as? [String] == ["--stdio", "--quiet"])
        #expect(decoded["namespace"] as? String == "notes")
        #expect(decoded["enabled"] as? Bool == true)
    }

    /// A server with no namespace prefixes nothing; the core takes `null` or an
    /// absent key, but never an empty string, which would namespace tools under
    /// "".
    @Test func upsertPayloadOmitsAnEmptyNamespace() throws {
        let json = mcpClientServerJSON(
            name: "notes", command: "notes-mcp", args: [], namespace: "", enabled: true
        )
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        #expect(decoded["namespace"] == nil || decoded["namespace"] is NSNull)
    }

    /// The payload carries no field the core does not know: the core refuses an
    /// unknown key outright rather than ignoring it.
    @Test func upsertPayloadCarriesNoUnknownField() throws {
        let json = mcpClientServerJSON(
            name: "notes", command: "notes-mcp", args: [], namespace: nil, enabled: false
        )
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let known: Set<String> = ["name", "command", "args", "namespace", "enabled"]
        #expect(Set(decoded.keys).isSubset(of: known))
        #expect(decoded["enabled"] as? Bool == false)
    }

    // MARK: What a client-run row offers

    private func clientServer(_ name: String, status: String = "enabled") -> McpClientServer {
        McpClientServer(name: name, transport: "stdio", status: status, toolCount: 0)
    }

    /// A daemon `McpServerView`, decoded from the wire shape because the type
    /// mirrors that shape and has no memberwise init.
    private func daemonView(_ name: String) throws -> McpServerView {
        let fields: [String: Any] = [
            "name": name,
            "command": "cmd",
            "args": [String](),
            "enabled": true,
            "status": "running",
            "tool_count": 0,
            "transport": "stdio",
            "target": "cmd",
        ]
        let data = try JSONSerialization.data(withJSONObject: fields)
        return try JSONDecoder().decode(McpServerView.self, from: data)
    }

    /// An external client-run row is administrable now: the core writes the
    /// machine-wide config on this client's behalf, so the row toggles and
    /// removes rather than explaining that it cannot.
    @Test func clientRunRowCanBeToggledAndRemoved() throws {
        let rows = mcpServerRows(daemon: [], client: [clientServer("notes")], builtins: [])
        let actions = mcpRowActions(for: try #require(rows.first))
        #expect(actions.canToggle)
        #expect(actions.canRemove)
    }

    /// A built-in stays non-removable: it is compiled into the client core, so
    /// there is nothing to delete.
    @Test func builtinRowStillCannotBeRemoved() throws {
        let builtin = McpBuiltinServer(
            name: "web", namespace: "web", toolCount: 1, overriddenBy: nil, disabledByConfig: false
        )
        let rows = mcpServerRows(daemon: [], client: [], builtins: [builtin])
        let actions = mcpRowActions(for: try #require(rows.first), builtin: builtin)
        #expect(actions.canToggle)
        #expect(!actions.canRemove)
    }

    /// A hosted client-run row reads on; one this surface has switched off reads
    /// off, and stays visible so it can be switched back on.
    @Test func clientRunToggleReadsThisSurfacesSelection() throws {
        let onRows = mcpServerRows(daemon: [], client: [clientServer("notes")], builtins: [])
        #expect(mcpClientRowIsOn(try #require(onRows.first)))

        let offRows = mcpServerRows(
            daemon: [], client: [clientServer("notes", status: "disabled")], builtins: []
        )
        #expect(!mcpClientRowIsOn(try #require(offRows.first)))
    }

    // MARK: The add form's location

    /// The form opens on the location that can be used: the daemon when there is
    /// a connection, this Mac when there is not.
    @Test func addLocationDefaultsToWhatTheConnectionAllows() {
        #expect(mcpDefaultAddLocation(connected: true) == .daemon)
        #expect(mcpDefaultAddLocation(connected: false) == .client)
        #expect(
            mcpCanAdd(location: mcpDefaultAddLocation(connected: false), connected: false),
            "the default location must be one the person can actually submit"
        )
    }

    /// Each location says what it means for the server being added, including
    /// when it starts.
    @Test func addFooterSaysWhatEachLocationMeans() throws {
        let daemon = try #require(mcpAddFooter(location: .daemon, connected: true, expanded: true))
        #expect(daemon.contains("daemon"))

        let client = try #require(mcpAddFooter(location: .client, connected: true, expanded: true))
        #expect(client.lowercased().contains("this mac"))
        #expect(
            client.lowercased().contains("next"),
            "a client-run server starts on the next connection, and must say so"
        )
    }

    /// A closed form has no location to describe: the picker is not on screen,
    /// so text about the daemon or this Mac describes a choice nobody made.
    @Test func addFooterDescribesNoLocationWhileTheFormIsClosed() {
        #expect(mcpAddFooter(location: .daemon, connected: false, expanded: false) == nil)
        #expect(mcpAddFooter(location: .daemon, connected: true, expanded: false) == nil)
        #expect(mcpAddFooter(location: .client, connected: false, expanded: false) == nil)
    }

    /// Adding a daemon server needs the daemon. Adding a client-run one does
    /// not: the config it writes is local to this machine.
    @Test func daemonAddNeedsAConnectionAndClientAddDoesNot() {
        #expect(!mcpCanAdd(location: .daemon, connected: false))
        #expect(mcpCanAdd(location: .daemon, connected: true))
        #expect(mcpCanAdd(location: .client, connected: false))
    }

    /// A disconnected panel says why the daemon option cannot be used, rather
    /// than offering a button that fails.
    @Test func addFooterExplainsADaemonAddWhileDisconnected() throws {
        let text = try #require(mcpAddFooter(location: .daemon, connected: false, expanded: true))
        #expect(text.lowercased().contains("connect"))
    }

    // MARK: Did the write land

    /// The panel judges an add by the population the core answered with: after
    /// an upsert the name is defined there.
    @Test func aLandedAddIsReadFromThePopulationTheCoreReturned() {
        #expect(mcpClientAddError(name: "notes", in: [clientServer("notes")]) == nil)
    }

    /// A refused write answers with the population still on disk, so the panel
    /// reports the add did not happen, and names the server.
    @Test func aRefusedAddIsReportedAgainstTheSameName() throws {
        let message = try #require(mcpClientAddError(name: "notes", in: []))
        #expect(message.contains("notes"))
    }

    /// A switched-off server still counts as defined: an upsert that turns it on
    /// landed even though the row is not running yet.
    @Test func aLandedAddCountsAServerThatIsSwitchedOff() {
        let off = clientServer("notes", status: "disabled")
        #expect(mcpClientAddError(name: "notes", in: [off]) == nil)
    }

    /// Names are compared the way the core compares them, so a server that
    /// differs only in case is not evidence the write landed.
    @Test func aRefusedAddIsNotHiddenByACaseDifferentName() {
        #expect(mcpClientAddError(name: "Notes", in: [clientServer("notes")]) != nil)
    }

    /// The write trims the typed name, so the check trims it too - otherwise a
    /// successful add reads as refused.
    @Test func theLandedCheckTrimsTheNameLikeTheWriteDoes() {
        #expect(mcpClientAddError(name: "  notes  ", in: [clientServer("notes")]) == nil)
    }

    // MARK: Name collisions

    /// A client-run name that matches a built-in overrides it - a supported
    /// arrangement, and how a person replaces a compiled-in server with their
    /// own. It is worth saying out loud, and it is not an error.
    @Test func addNoteWarnsThatAClientNameOverridesABuiltin() {
        let builtin = McpBuiltinServer(
            name: "web", namespace: "web", toolCount: 1, overriddenBy: nil, disabledByConfig: false
        )
        let rows = mcpServerRows(daemon: [], client: [], builtins: [builtin])
        let note = mcpAddNameNote(name: "web", location: .client, rows: rows)
        #expect(note?.contains("built-in") == true)
    }

    /// A client-run name that matches an existing client-run server edits that
    /// server, rather than creating a second one.
    @Test func addNoteSaysAKnownClientNameIsAnEdit() {
        let rows = mcpServerRows(daemon: [], client: [clientServer("notes")], builtins: [])
        let note = mcpAddNameNote(name: "notes", location: .client, rows: rows)
        #expect(note?.lowercased().contains("replace") == true)
    }

    /// A fresh name says nothing.
    @Test func addNoteIsSilentForAFreshName() {
        let rows = mcpServerRows(daemon: [], client: [clientServer("notes")], builtins: [])
        #expect(mcpAddNameNote(name: "calendar", location: .client, rows: rows) == nil)
    }

    /// A daemon-run and a client-run server may share a name: they are separate
    /// populations, and the panel already sorts the pair. Adding one over the
    /// other is not an edit of it, so the note must not claim it is.
    @Test func addNoteDoesNotConfuseTheTwoPopulations() throws {
        let rows = mcpServerRows(daemon: [try daemonView("notes")], client: [], builtins: [])
        #expect(mcpAddNameNote(name: "notes", location: .client, rows: rows) == nil)
    }

    /// Every name comparison in the core is exact, so the note's must be too. A
    /// name that differs only in case creates a separate definition: it
    /// overrides no built-in, and edits no client-run server.
    @Test func addNoteMatchesNamesExactlyLikeTheCore() {
        let builtin = McpBuiltinServer(
            name: "web", namespace: "web", toolCount: 1, overriddenBy: nil, disabledByConfig: false
        )
        let rows = mcpServerRows(
            daemon: [], client: [clientServer("notes")], builtins: [builtin]
        )
        #expect(mcpAddNameNote(name: "Web", location: .client, rows: rows) == nil)
        #expect(mcpAddNameNote(name: "Notes", location: .client, rows: rows) == nil)
    }

    /// A server of that name that is switched off here does not "already run
    /// here". The add turns it back on, so the note says that instead.
    @Test func addNoteSaysASwitchedOffServerWillBeTurnedOn() throws {
        let rows = mcpServerRows(
            daemon: [], client: [clientServer("notes", status: "disabled")], builtins: []
        )
        let note = try #require(mcpAddNameNote(name: "notes", location: .client, rows: rows))
        #expect(note.lowercased().contains("switched off"))
        #expect(note.lowercased().contains("turns it on"))
        #expect(!note.lowercased().contains("already runs here"))
    }
}
