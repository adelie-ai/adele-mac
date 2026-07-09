import AdeleCore
import Observation
import SwiftUI

/// A message as rendered in the transcript. `streaming` marks the in-progress
/// assistant bubble that `chunk` events append to and `complete` finalizes.
struct DisplayMessage: Identifiable, Hashable {
    let id: String
    let role: String
    var content: String
    var streaming: Bool = false

    var isUser: Bool { role == "user" }
}

/// The app's render state. Holds the single `AdeleCore` for the process lifetime
/// and folds each pushed `ViewEvent` into observable state SwiftUI renders. This
/// is the only place events are interpreted — the reducer in Rust already decided
/// the deltas.
@MainActor
@Observable
final class AppModel {
    private let core = AdeleCore()

    // Connection
    var connected = false
    var connecting = false
    var connectionError: String?
    var serverAddress = "ws://127.0.0.1:11339/ws"
    var username = "adele"
    var password = ""

    // Sidebar
    var conversations: [ConversationSummary] = []
    var selectedConversationID: String?

    // Transcript
    var messages: [DisplayMessage] = []
    var chatStatus: String?
    var statusText = ""
    var sendEnabled = true
    var contextReadout: String?

    // Composer
    var draft = ""

    init() {
        core.onEvent = { [weak self] event in
            self?.apply(event)
        }
    }

    // MARK: - Intents

    func connect() {
        guard !serverAddress.isEmpty else { return }
        connecting = true
        connectionError = nil
        let (url, user, pass) = (serverAddress, username, password)
        Task {
            do {
                // macOS has no D-Bus token minter — fetch a bearer token from the
                // daemon's /login and stage it before opening the socket.
                let token = try await WSLogin.token(wsURL: url, username: user, password: pass)
                core.setWSJWT(token)
                core.connect(transport: "ws", address: url)
                // Success/failure now arrives as a connected / connect_error event.
            } catch {
                connecting = false
                connectionError = "\(error)"
            }
        }
    }

    func newConversation() {
        core.newConversation()
    }

    func selectConversation(_ id: String) {
        guard id != selectedConversationID else { return }
        selectedConversationID = id
        core.selectConversation(id)
    }

    func deleteConversation(_ id: String) {
        core.deleteConversation(id)
        if selectedConversationID == id {
            selectedConversationID = nil
            messages = []
        }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, sendEnabled else { return }
        draft = ""
        core.sendPrompt(text)
    }

    // MARK: - Event folding

    private func apply(_ event: ViewEvent) {
        switch event {
        case .connected(let label):
            connected = true
            connecting = false
            connectionError = nil
            statusText = "Connected: \(label)"

        case .connectError(let message):
            connected = false
            connecting = false
            connectionError = message
            statusText = "Connection failed"

        case .clientCleared:
            connected = false
            connecting = false
            statusText = "Disconnected"

        case .status(let text):
            statusText = text

        case .sendSensitive(let value):
            sendEnabled = value

        case .conversations(let items):
            conversations = items

        case .loadConversation(let detail):
            selectedConversationID = detail.id
            messages = detail.messages.map {
                DisplayMessage(id: $0.id, role: $0.role, content: $0.content)
            }

        case .clearChat:
            messages = []

        case .chatStatus(let text):
            chatStatus = text

        case .clearChatStatus:
            chatStatus = nil

        case .contextUsage(let usage):
            contextReadout = usage?.readout

        case .addUserMessage(let content):
            appendUser(content)

        case .chunk(let text):
            appendChunk(text)

        case .complete(let text):
            completeStreaming(text)

        case .toast, .inlineNote, .unknown:
            // Phase 1: no dedicated surface yet.
            break
        }
    }

    private func appendUser(_ content: String) {
        messages.append(DisplayMessage(id: freshID(), role: "user", content: content))
    }

    private func appendChunk(_ text: String) {
        if let last = messages.indices.last,
           messages[last].streaming, messages[last].role == "assistant" {
            messages[last].content += text
        } else {
            messages.append(
                DisplayMessage(id: freshID(), role: "assistant", content: text, streaming: true)
            )
        }
    }

    private func completeStreaming(_ text: String) {
        if let last = messages.indices.last,
           messages[last].streaming, messages[last].role == "assistant" {
            messages[last].content = text
            messages[last].streaming = false
        } else {
            messages.append(DisplayMessage(id: freshID(), role: "assistant", content: text))
        }
    }

    // Client-side id for optimistic/streamed bubbles the daemon hasn't numbered.
    private var localCounter = 0
    private func freshID() -> String {
        localCounter += 1
        return "local-\(localCounter)"
    }
}
