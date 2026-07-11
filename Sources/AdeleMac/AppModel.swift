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
    /// An inline transcript note (e.g. a "(speech mode disabled)" downgrade),
    /// rendered centered rather than as a chat bubble.
    var isNote: Bool { role == "note" }
}

/// The app's render state. Holds the single `AdeleCore` for the process lifetime
/// and folds each pushed `ViewEvent` into observable state SwiftUI renders. This
/// is the only place events are interpreted — the reducer in Rust already decided
/// the deltas.
@MainActor
@Observable
final class AppModel {
    /// The single shared core. Exposed (not private) so per-feature settings
    /// views can issue management commands directly through it.
    let core = AdeleCore()

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
    var contextUsage: ContextUsage?

    // Models
    var models: [ModelListing] = []
    var modelSelection: ModelSelection?
    var defaultModel: SelectedModel?
    var modelPickerVisible = false

    // Background tasks
    var tasks: [TaskView] = []
    var taskLogs: [String: [TaskLogEntry]] = [:]
    var activeTaskCount: Int { tasks.filter(\.isActive).count }

    // Scratchpad side pane
    var scratchpad: [ScratchpadNote] = []
    var showScratchpad = false

    // Voice output (Adele speaks)
    private let speaker = Speaker()
    /// "disabled" | "on_demand" | "always".
    var adeleOutputLevel = "disabled"

    // Transient toast
    var toast: String?
    private var toastTask: Task<Void, Never>?

    // Composer
    var draft = ""

    // Connection profiles
    var profiles: [Profile] = []
    var currentProfileID: String?
    private var store = ProfileStore()

    // Settings / management
    var connections: [ConnectionView] = []
    var purposes = PurposesView()
    var settingsError: String?
    var settingsLoading = false

    // Knowledge base
    var knowledgeEntries: [KnowledgeEntry] = []
    var knowledgeSearch = ""
    var showKnowledge = false
    var knowledgeLoading = false

    init() {
        core.onEvent = { [weak self] event in
            self?.apply(event)
        }
        store = ProfileStore.load()
        profiles = store.profiles
    }

    // MARK: - Profiles

    /// On launch: reconnect to the last-used profile if its password is saved.
    func autoReconnect() {
        guard currentProfileID == nil, !connected, !connecting,
              let lastID = store.lastProfileID,
              let profile = profiles.first(where: { $0.id == lastID }),
              let saved = Keychain.password(for: profile.id)
        else { return }
        use(profile, password: saved)
        connect()
    }

    /// Load a profile into the form (password from the Keychain).
    func use(_ profile: Profile, password saved: String? = nil) {
        serverAddress = profile.wsURL
        username = profile.username
        password = saved ?? Keychain.password(for: profile.id) ?? ""
        currentProfileID = profile.id
    }

    func connect(using profile: Profile) {
        use(profile)
        connect()
    }

    /// Reconnect to a different profile without restarting (clears view state; the
    /// reducer re-emits conversations for the new connection).
    func switchProfile(_ profile: Profile) {
        guard profile.id != currentProfileID else { return }
        conversations = []
        messages = []
        selectedConversationID = nil
        use(profile)
        connect()
    }

    var currentProfile: Profile? { profiles.first { $0.id == currentProfileID } }

    func deleteProfile(_ profile: Profile) {
        Keychain.deletePassword(for: profile.id)
        profiles.removeAll { $0.id == profile.id }
        if store.lastProfileID == profile.id { store.lastProfileID = nil }
        if currentProfileID == profile.id { currentProfileID = nil }
        persistProfiles()
    }

    @discardableResult
    private func upsertProfile() -> Profile {
        if let idx = profiles.firstIndex(where: {
            $0.wsURL == serverAddress && $0.username == username
        }) {
            currentProfileID = profiles[idx].id
            return profiles[idx]
        }
        let name = URL(string: serverAddress)?.host ?? serverAddress
        let profile = Profile(name: name, wsURL: serverAddress, username: username)
        profiles.append(profile)
        currentProfileID = profile.id
        return profile
    }

    private func persistProfiles() {
        store.profiles = profiles
        store.lastProfileID = currentProfileID
        store.save()
    }

    // MARK: - Intents

    func connect() {
        guard !serverAddress.isEmpty else { return }
        connecting = true
        connectionError = nil
        // Remember this target as a profile and stash its password in the Keychain.
        let profile = upsertProfile()
        Keychain.setPassword(password, for: profile.id)
        persistProfiles()
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

    /// Set the Adele-output (spoken reply) level for the open conversation:
    /// "disabled" | "on_demand" | "always".
    func setAdeleOutput(_ level: String) {
        guard let id = selectedConversationID else { return }
        adeleOutputLevel = level
        core.setAdeleOutput(conversationID: id, level: level)
        if level == "disabled" { speaker.stop() }
    }

    func stopSpeaking() {
        speaker.stop()
    }

    func selectModel(_ listing: ModelListing, effort: String = "") {
        core.selectModel(
            connectionID: listing.connectionId,
            modelID: listing.model.id,
            effort: effort
        )
    }

    /// Clear the per-conversation override (inherit the interactive default).
    func clearModelOverride() {
        core.selectModel(connectionID: "", modelID: "", effort: "")
    }

    /// The label shown on the model-picker button: the selected model's display
    /// name (falling back to the resolved default, then a placeholder).
    var currentModelLabel: String {
        if let selection = modelSelection,
           let listing = models.first(where: {
               $0.connectionId == selection.connectionId && $0.model.id == selection.modelId
           }) {
            return listing.model.displayName
        }
        if let def = defaultModel,
           let listing = models.first(where: {
               $0.connectionId == def.connectionId && $0.model.id == def.modelId
           }) {
            return listing.model.displayName
        }
        return "Model"
    }

    func isSelected(_ listing: ModelListing) -> Bool {
        guard let selection = modelSelection else { return false }
        return selection.connectionId == listing.connectionId
            && selection.modelId == listing.model.id
    }

    // MARK: - Settings / management

    func loadSettings() {
        guard connected else { return }
        settingsLoading = true
        settingsError = nil
        Task {
            do {
                async let conns = core.listConnections()
                async let purps = core.getPurposes()
                connections = try await conns
                purposes = try await purps
            } catch {
                settingsError = "\(error)"
            }
            settingsLoading = false
        }
    }

    func purpose(for kind: String) -> PurposeConfigView? {
        switch kind {
        case "interactive": return purposes.interactive
        case "dreaming": return purposes.dreaming
        case "consolidation": return purposes.consolidation
        case "embedding": return purposes.embedding
        case "titling": return purposes.titling
        default: return nil
        }
    }

    /// Assign a purpose (e.g. "interactive") to a model. Reloads purposes after.
    func setPurpose(_ purpose: String, connectionID: String, modelID: String) {
        Task {
            do {
                try await core.setPurpose(purpose, connection: connectionID, model: modelID)
                purposes = try await core.getPurposes()
            } catch {
                settingsError = "\(error)"
            }
        }
    }

    // MARK: - Knowledge base

    func loadKnowledge() {
        guard connected else { return }
        knowledgeLoading = true
        settingsError = nil
        let query = knowledgeSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                knowledgeEntries = query.isEmpty
                    ? try await core.listKnowledgeEntries()
                    : try await core.searchKnowledgeEntries(query)
            } catch {
                settingsError = "\(error)"
            }
            knowledgeLoading = false
        }
    }

    func saveKnowledge(id: String?, content: String, tags: [String]) {
        Task {
            do {
                if let id {
                    try await core.updateKnowledgeEntry(id: id, content: content, tags: tags)
                } else {
                    try await core.createKnowledgeEntry(content: content, tags: tags)
                }
                loadKnowledge()
            } catch {
                settingsError = "\(error)"
            }
        }
    }

    func deleteKnowledge(id: String) {
        Task {
            do {
                try await core.deleteKnowledgeEntry(id: id)
                loadKnowledge()
            } catch {
                settingsError = "\(error)"
            }
        }
    }

    // MARK: - Tasks

    func cancelTask(_ id: String) {
        core.cancelTask(id)
    }

    func fetchTaskLogs(_ id: String) {
        core.fetchTaskLogs(id)
    }

    private func upsertTask(_ task: TaskView) {
        if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[idx] = task
        } else {
            tasks.append(task)
        }
    }

    var selectedListing: ModelListing? {
        guard let selection = modelSelection else { return nil }
        return models.first {
            $0.connectionId == selection.connectionId && $0.model.id == selection.modelId
        }
    }

    /// Models grouped by connection, preserving first-seen order.
    var modelsByConnection: [(label: String, listings: [ModelListing])] {
        var order: [String] = []
        var groups: [String: (label: String, listings: [ModelListing])] = [:]
        for listing in models {
            if groups[listing.connectionId] == nil {
                order.append(listing.connectionId)
                groups[listing.connectionId] = (listing.connectionLabel, [])
            }
            groups[listing.connectionId]?.listings.append(listing)
        }
        return order.compactMap { groups[$0] }
    }

    // MARK: - Event folding

    private func apply(_ event: ViewEvent) {
        switch event {
        case .connected(let label):
            connected = true
            connecting = false
            connectionError = nil
            statusText = "Connected: \(label)"
            persistProfiles()  // record this as the last-used profile

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
            contextUsage = usage

        case .models(let items):
            models = items

        case .modelSelection(let selection):
            modelSelection = selection

        case .defaultModel(let model):
            defaultModel = model

        case .modelPickerVisible(let value):
            modelPickerVisible = value

        case .tasksReplaceAll(let items):
            tasks = items

        case .taskStarted(let task):
            upsertTask(task)

        case .taskProgress(let id, let hint):
            if let idx = tasks.firstIndex(where: { $0.id == id }) {
                tasks[idx].progressHint = hint
            }

        case .taskLogAppended(let id, let entry):
            taskLogs[id, default: []].append(entry)

        case .taskCompleted(let id):
            // The terminal event carries only the id; a later tasks_replace_all
            // corrects the precise status (completed/failed/cancelled).
            if let idx = tasks.firstIndex(where: { $0.id == id }), tasks[idx].isActive {
                tasks[idx].status = "completed"
            }

        case .taskLogs(let id, let entries):
            taskLogs[id] = entries

        case .scratchpad(let notes):
            scratchpad = notes

        case .addUserMessage(let content):
            appendUser(content)

        case .chunk(let text):
            appendChunk(text)

        case .complete(let text):
            completeStreaming(text)

        case .speak(let text):
            speaker.speak(text)

        case .adeleOutputDropdown(let level):
            adeleOutputLevel = level

        case .toast(let text):
            showToast(text)

        case .inlineNote(let text):
            messages.append(DisplayMessage(id: freshID(), role: "note", content: text))

        case .unknown:
            break
        }
    }

    private func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.toast = nil
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
