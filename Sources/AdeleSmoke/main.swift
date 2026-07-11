import AdeleCore
import Foundation

// Headless end-to-end smoke test for the shared Rust core over WebSocket.
//
// Flow: obtain a bearer token (explicit ADELE_WS_JWT, or /login with
// ADELE_WS_USER/ADELE_WS_PASS) → create the core → stage the token → connect →
// on `connected`, open a new conversation → on the conversation loading, send the
// prompt → print streamed chunks → exit on `complete` (or on error / timeout).
//
// Env:
//   ADELE_WS_URL   (default ws://127.0.0.1:11339/ws)
//   ADELE_WS_JWT   explicit bearer token (skips /login)
//   ADELE_WS_USER  /login username (default "adele")
//   ADELE_WS_PASS  /login password
//   ADELE_PROMPT   prompt to send (default a short greeting)
//   ADELE_TIMEOUT  seconds before giving up (default 90)

let env = ProcessInfo.processInfo.environment
let wsURL = env["ADELE_WS_URL"] ?? "ws://127.0.0.1:11339/ws"
let prompt = env["ADELE_PROMPT"] ?? "Reply with a short one-sentence greeting."
let timeout = Double(env["ADELE_TIMEOUT"] ?? "") ?? 90

func log(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func finish(_ code: Int32, _ message: String) -> Never {
    log(message)
    exit(code)
}

let core = AdeleCore()
var isConnected = false
var promptSent = false

core.onEvent = { event in
    switch event {
    case .connected(let label):
        log("✅ connected: \(label)")
        isConnected = true
        if env["ADELE_MGMT"] == "1" {
            Task { @MainActor in
                do {
                    let conns = try await core.listConnections()
                    log("• connections: \(conns.map { "\($0.id)[\($0.availability.isOk ? "ok" : "down")]" }.joined(separator: ", "))")
                    let purposes = try await core.getPurposes()
                    log("• interactive purpose: \(purposes.interactive?.model ?? "unset")")
                    if let setModel = env["ADELE_SET_INTERACTIVE"], let conn = env["ADELE_SET_CONN"] {
                        try await core.setPurpose("interactive", connection: conn, model: setModel)
                        let after = try await core.getPurposes()
                        log("✅ set interactive → \(after.interactive?.model ?? "?")")
                    }
                    finish(0, "✅ management bridge works")
                } catch {
                    finish(1, "❌ management failed: \(error)")
                }
            }
            return
        }
        // Start a fresh conversation so streamed chunks land in the open
        // conversation (an auto-opened existing one may arrive before `connected`).
        core.newConversation()
    case .connectError(let message):
        finish(1, "❌ connect_error: \(message)")
    case .status(let text):
        log("• status: \(text)")
    case .conversations(let items):
        log("• conversations: \(items.count)")
    case .models(let items):
        log("• models: \(items.count)" + (items.first.map { " (e.g. \($0.connectionLabel)/\($0.model.displayName))" } ?? ""))
    case .defaultModel(let m):
        log("• default model: \(m.map { "\($0.connectionId)/\($0.modelId)" } ?? "none")")
    case .modelSelection(let s):
        log("• model selection: \(s.map { "\($0.connectionId)/\($0.modelId) effort=\($0.effort ?? "-")" } ?? "none")")
    case .loadConversation(let detail):
        log("• conversation open: \(detail.id) (\(detail.messages.count) msgs)")
        // Only send into the empty conversation opened after we connected — the
        // one newConversation() just created and left as the open conversation.
        if isConnected, !promptSent, detail.messages.isEmpty {
            promptSent = true
            if env["ADELE_SPEAK"] == "1" {
                log("→ enabling Adele voice output (always)")
                core.setAdeleOutput(conversationID: detail.id, level: "always")
            }
            log("→ sending prompt: \(prompt)")
            core.sendPrompt(prompt)
        }
    case .addUserMessage(let content):
        log("• user: \(content)")
    case .chatStatus(let text):
        log("• …\(text)")
    case .speak(let text):
        log("🔊 speak: \(text)")
    case .adeleOutputDropdown(let level):
        log("• adele output level: \(level)")
    case .chunk(let text):
        FileHandle.standardOutput.write(Data(text.utf8))
    case .complete(let text):
        FileHandle.standardOutput.write(Data("\n".utf8))
        finish(0, "✅ complete (\(text.count) chars) — end-to-end streaming works")
    default:
        break
    }
}

Task {
    let token: String
    if let explicit = env["ADELE_WS_JWT"], !explicit.isEmpty {
        token = explicit
    } else {
        guard let pass = env["ADELE_WS_PASS"] else {
            finish(2, "no ADELE_WS_JWT and no ADELE_WS_PASS — cannot authenticate")
        }
        do {
            token = try await WSLogin.token(
                wsURL: wsURL,
                username: env["ADELE_WS_USER"] ?? "adele",
                password: pass
            )
            log("🔑 obtained /login token (\(token.count) chars)")
        } catch {
            finish(2, "login failed: \(error)")
        }
    }
    core.setWSJWT(token)
    log("🔌 connecting to \(wsURL) …")
    core.connect(transport: "ws", address: wsURL)
}

DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
    finish(3, "⏱️ timed out after \(Int(timeout))s")
}

dispatchMain()
