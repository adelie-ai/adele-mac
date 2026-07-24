import CAdeleCore
import Foundation

// Swift-facing core for the Adelie chat client. Owns ONE instance of the shared
// Rust core (`libadele_client_core`), which itself owns the `client-ui-common`
// reducer (the same WindowState state machine gtk/tui/kde run) plus a
// `client-common` Connector. All model, controller, and transport logic lives in
// Rust; this object is glue: it forwards user intents to the core and turns the
// core's pushed JSON view-events into typed `ViewEvent`s delivered on the main
// actor.
//
// Threading: the core's view-event callback fires on a Rust worker thread. The
// static C trampoline copies the JSON, hops to the main thread, decodes it, and
// invokes `onEvent`. Marshalling to the UI thread before touching UI state is
// the same discipline adele-kde follows with a queued Qt connection.
//
// Lifetime: `user_data` is an unretained pointer to `self`, mirroring the KDE
// glue. The single instance is expected to live for the app's lifetime; on
// `deinit`, `adele_core_free` shuts the runtime down (joining the worker threads)
// so no callback outlives the object.
//
// `@unchecked Sendable`: this type crosses threads by design — the Rust core
// invokes the view-event callback from a worker thread, which then hands the
// decoded event to the main actor. The invariants that make that sound: `handle`
// is set once in `init` and only read thereafter (the core is internally an
// actor, safe to call from any thread), and `onEvent` is assigned once by the
// owner at setup before any connect drives callbacks.
public final class AdeleCore: @unchecked Sendable {
    // Readable module-wide so per-feature intents can live in their own
    // `extension AdeleCore` files (e.g. AdeleCore+Queued.swift); only this file
    // ever assigns it (once, in `init`).
    private(set) var handle: OpaquePointer?

    /// Delivered on the main actor, one per pushed view-event.
    public var onEvent: (@MainActor (ViewEvent) -> Void)?

    /// In-flight management commands, keyed by request id. Accessed only on the
    /// main actor (both `sendCommand` and the reply in `dispatch` run there).
    private var pendingCommands: [String: CheckedContinuation<Data, Error>] = [:]

    /// Callers awaiting the next built-in MCP inventory. Not keyed by request id:
    /// the core's `mcp_builtins` event carries no correlation id because it is
    /// also emitted unsolicited (after a toggle), and the inventory is whole-set
    /// state rather than a per-request answer — so the next one to arrive is the
    /// right answer for everyone waiting. Main-actor only, like `pendingCommands`.
    private var pendingBuiltins: [CheckedContinuation<[McpBuiltinServer], Never>] = []

    /// Callers awaiting the next external client-run MCP inventory. Not keyed by
    /// request id, for the same reason as ``pendingBuiltins``: the core's
    /// `mcp_client_servers` event carries no correlation id and the inventory is
    /// whole-set state, so the next one to arrive answers everyone waiting.
    /// Main-actor only.
    private var pendingClientServers: [CheckedContinuation<[McpClientServer], Never>] = []

    public init() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        handle = adele_core_new({ userData, json in
            // Rust worker-thread context. Only copy the JSON and hand off — no
            // access to Swift state beyond reconstructing the unretained pointer.
            guard let userData, let json else { return }
            let core = Unmanaged<AdeleCore>.fromOpaque(userData).takeUnretainedValue()
            let jsonString = String(cString: json)
            core.dispatch(jsonString)
        }, ctx)
    }

    deinit {
        if let handle {
            adele_core_free(handle)
        }
    }

    private func dispatch(_ json: String) {
        guard let data = json.data(using: .utf8) else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Management command replies are correlated to their awaiting
                // caller, not folded into the UI event stream.
                if let head = try? JSONDecoder().decode(CommandResultHead.self, from: data),
                   head.type == "command_result" {
                    if let continuation = self.pendingCommands.removeValue(forKey: head.requestID) {
                        if head.ok {
                            continuation.resume(returning: data)
                        } else {
                            continuation.resume(throwing: CommandError.failed(head.error ?? "command failed"))
                        }
                    }
                    return
                }
                if let event = try? JSONDecoder().decode(ViewEvent.self, from: data) {
                    // The built-in inventory resolves anyone awaiting it AND is
                    // still forwarded, so an unsolicited refresh (the core emits
                    // one after a toggle) reaches the UI either way.
                    if case .mcpBuiltins(_, let servers) = event, !self.pendingBuiltins.isEmpty {
                        let waiting = self.pendingBuiltins
                        self.pendingBuiltins.removeAll()
                        for continuation in waiting { continuation.resume(returning: servers) }
                    }
                    // Same contract for the external client-run inventory.
                    if case .mcpClientServers(_, let servers) = event,
                       !self.pendingClientServers.isEmpty {
                        let waiting = self.pendingClientServers
                        self.pendingClientServers.removeAll()
                        for continuation in waiting { continuation.resume(returning: servers) }
                    }
                    self.onEvent?(event)
                }
            }
        }
    }

    /// Send a management `api::Command` (JSON) and await its `CommandResult`. The
    /// returned `Data` is the full `command_result` event; decode its `result`
    /// field with `CommandResultEnvelope<T>`.
    @MainActor
    public func sendCommand(_ commandJSON: String) async throws -> Data {
        guard handle != nil else { throw CommandError.failed("core not initialized") }
        let requestID = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            pendingCommands[requestID] = continuation
            adele_core_send_command(handle, requestID, commandJSON)
        }
    }

    // MARK: - Intents (fire-and-forget; results arrive later via `onEvent`)

    /// Connect to the daemon. `transport` = "ws" | "uds" | "dbus"; `address` is
    /// the WS url or UDS socket path (empty = default). Outcome arrives as a
    /// `connected` / `connect_error` event, never a return value.
    public func connect(transport: String = "ws", address: String) {
        guard let handle else { return }
        adele_core_connect(handle, transport, address)
    }

    /// Stage an explicit WS bearer token for the next `connect` (empty ⇒ clear).
    /// macOS has no D-Bus token minter, so the app fetches a token from the
    /// daemon's `/login` (see `WSLogin`) and hands it over here before connecting.
    public func setWSJWT(_ jwt: String) {
        guard let handle else { return }
        adele_core_set_ws_jwt(handle, jwt)
    }

    /// Stage the "share device info with the assistant" opt-out (#549) for the
    /// next `connect`. `true` (the default) lets the daemon fold this Mac's
    /// context — device name, username, home folder, hostname, time zone, OS —
    /// into the system prompt; `false` sends none of it. The core stages the flag
    /// and applies it when the next (re)connect builds its `ConnectionConfig`, so
    /// a change takes effect on the following connection, not the live one.
    public func setShareClientContext(_ enabled: Bool) {
        guard let handle else { return }
        adele_core_set_share_client_context(handle, enabled)
    }

    /// This client's `client-mcp.toml` surface name. Must match an entry in
    /// `client-common`'s `CLIENT_SURFACES`, which is the shared source of truth
    /// admin UIs enumerate — a name absent from that list resolves nothing.
    public static let macMcpSurface = "mac"

    /// Declare which `client-mcp.toml` surface this client resolves its MCP
    /// servers (and built-in opt-outs) under. Server definitions are
    /// machine-wide; the surface is the per-client enable layer, so the same
    /// servers can be configured once and switched on per client.
    ///
    /// The core shares its cdylib with adele-kde and defaults to `kde`, so this
    /// must be set before `connect` or the Mac silently adopts KDE's selection.
    public func setMcpSurface(_ surface: String) {
        guard let handle else { return }
        adele_core_set_mcp_surface(handle, surface)
    }

    /// The MCP servers compiled into the core and hosted in-process, with each
    /// one's status under this client's surface: its namespace and live tool
    /// count, the same-name external server shadowing it (if any), and whether
    /// this surface has opted out of it.
    ///
    /// Answerable with no connection — which servers are built in is decided when
    /// the core is built (`just build-with-mcp`), and the opt-out is a local file
    /// — so a settings panel can call this before the first connect. A core built
    /// with no MCP servers linked in answers with an empty array, which is the
    /// honest "none compiled in".
    @MainActor
    public func mcpBuiltinServers() async -> [McpBuiltinServer] {
        guard let handle else { return [] }
        return await withCheckedContinuation { continuation in
            pendingBuiltins.append(continuation)
            adele_core_request_mcp_builtins(handle)
        }
    }

    /// The external client-run MCP servers this client hosts on the edge — the
    /// `client-mcp.toml` servers this client's surface enables — with each one's
    /// transport, live tool count, and status.
    ///
    /// Answerable with no connection, the sibling of ``mcpBuiltinServers()``:
    /// which external servers this surface hosts is a property of
    /// `client-mcp.toml`, so a settings panel can call this before the first
    /// connect. The list is complete offline (each server reports `enabled` with
    /// a `0` tool count); the live tool counts and running/error status fill in
    /// once a connection has started the client MCP host. A surface with no
    /// external servers answers with an empty array.
    @MainActor
    public func mcpClientServers() async -> [McpClientServer] {
        // Spec stub: the FFI read path is not wired yet, so the panel renders no
        // client-run rows. The tests pin what the implementation must deliver.
        []
    }

    /// Turn one built-in MCP server off or back on **for this client's surface**,
    /// returning the refreshed inventory once the core has written it.
    ///
    /// The core owns the write: `client-mcp.toml` is machine-wide and every Adele
    /// client on the box reads the same file, so a second writer here would be a
    /// correctness hazard for all of them. Only this client's surface section is
    /// touched.
    ///
    /// The change takes effect on the next connect — a running MCP host is fixed
    /// at start — but the returned inventory already reflects it, so the panel can
    /// show the pending state rather than looking unchanged. A failed write comes
    /// back as a `toast` event plus an inventory that still shows the truth on
    /// disk.
    @MainActor
    @discardableResult
    public func setMcpBuiltinDisabled(name: String, disabled: Bool) async -> [McpBuiltinServer] {
        guard let handle else { return [] }
        return await withCheckedContinuation { continuation in
            // No separate read request: the core emits a fresh inventory of its
            // own accord once the write lands, so awaiting that one avoids racing
            // a concurrent read against the write.
            pendingBuiltins.append(continuation)
            adele_core_set_mcp_builtin_disabled(handle, name, disabled)
        }
    }

    public func sendPrompt(_ text: String) {
        guard let handle else { return }
        adele_core_send_prompt(handle, text)
    }

    public func selectConversation(_ conversationID: String) {
        guard let handle else { return }
        adele_core_select_conversation(handle, conversationID)
    }

    public func newConversation() {
        guard let handle else { return }
        adele_core_new_conversation(handle)
    }

    public func deleteConversation(_ conversationID: String) {
        guard let handle else { return }
        adele_core_delete_conversation(handle, conversationID)
    }

    public func setVoiceIn(conversationID: String, enabled: Bool) {
        guard let handle else { return }
        adele_core_set_voice_in(handle, conversationID, enabled)
    }

    /// `level` = "disabled" | "on_demand" | "always".
    public func setAdeleOutput(conversationID: String, level: String) {
        guard let handle else { return }
        adele_core_set_adele_output(handle, conversationID, level)
    }

    /// Empty `connectionID`/`modelID` clears the override; `effort` = "low" |
    /// "medium" | "high" or empty.
    public func selectModel(connectionID: String, modelID: String, effort: String = "") {
        guard let handle else { return }
        adele_core_select_model(handle, connectionID, modelID, effort)
    }

    public func cancelTask(_ taskID: String) {
        guard let handle else { return }
        adele_core_cancel_task(handle, taskID)
    }

    public func fetchTaskLogs(_ taskID: String) {
        guard let handle else { return }
        adele_core_fetch_task_logs(handle, taskID)
    }
}
