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
