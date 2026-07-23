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
    /// Presentation metadata (voice#126): `.spoken` / `.speechDisabled` turns get
    /// a badge in the transcript, `.normal` ones (nearly all) get nothing.
    var kind: MessageKind = .normal

    var isUser: Bool { role == "user" }
    /// An inline transcript note (e.g. a speech-disabled downgrade, whose marker
    /// now lives in `kind`), rendered centered rather than as a chat bubble.
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
    /// User-curated subset shown in the picker (persisted). Empty = show all.
    var selectedModels = SelectedModelsStore.load()

    func reloadSelectedModels() { selectedModels = .load() }

    /// The models the picker should show, after the user's select-models filter.
    var pickerModels: [ModelListing] { selectedModels.filter(models) }

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

    // Speech voice preferences (persisted in UserDefaults). `nil` voice = system
    // default; rate is an AVSpeechUtterance rate (0…1); pitch is 0.5…2.0.
    var voiceIdentifier: String? = nil {
        didSet { UserDefaults.standard.set(voiceIdentifier, forKey: "voiceIdentifier") }
    }
    var speechRate: Double = 0.5 {
        didSet { UserDefaults.standard.set(speechRate, forKey: "speechRate") }
    }
    var speechPitch: Double = 1.0 {
        didSet { UserDefaults.standard.set(speechPitch, forKey: "speechPitch") }
    }

    // Privacy: "Share device info with the assistant" (#549). Persisted locally;
    // every change is staged on the core, which applies it when the next
    // (re)connect builds its config — the Privacy settings tab says so.
    private let clientContextPrefs = ClientContextPreference()
    var shareClientContext = ClientContextPreference.defaultValue {
        didSet {
            clientContextPrefs.isEnabled = shareClientContext
            core.setShareClientContext(shareClientContext)
        }
    }

    // Transient toast
    var toast: String?
    private var toastTask: Task<Void, Never>?

    // Composer
    /// Half-typed text, keyed by conversation id (#7) — switching conversations
    /// restores that conversation's draft instead of carrying one across.
    var drafts = DraftStore()
    /// The live composer text for the open conversation.
    var draft: String {
        get { drafts[selectedConversationID] }
        set { drafts[selectedConversationID] = newValue }
    }
    /// The open conversation's message queue (#1), replaced wholesale by each
    /// `queued_messages` event.
    var queued = QueuedMessagesState()

    // Connection profiles
    var profiles: [Profile] = []
    var currentProfileID: String?
    private var store = ProfileStore()

    // Settings / management
    var connections: [ConnectionView] = []
    var purposes = PurposesView()
    var settingsError: String?
    var settingsLoading = false

    // Knowledge base (intents + event handling live in AppModel+Knowledge.swift)
    var knowledgeEntries: [KnowledgeEntry] = []
    var knowledgeSearch = ""
    var showKnowledge = false
    var knowledgeLoading = false
    /// Debounce token for `knowledge_changed`-driven refetches.
    var knowledgeRefreshTask: Task<Void, Never>?
    /// Background-task ids of maintenance runs we started, so their completion
    /// can refresh the browser.
    var knowledgeMaintenanceTaskIDs: Set<String> = []

    init() {
        core.onEvent = { [weak self] event in
            self?.apply(event)
        }
        store = ProfileStore.load()
        profiles = store.profiles

        // Load persisted voice preferences (init assignments don't fire didSet).
        let defaults = UserDefaults.standard
        voiceIdentifier = defaults.string(forKey: "voiceIdentifier")
        if defaults.object(forKey: "speechRate") != nil {
            speechRate = defaults.double(forKey: "speechRate")
        }
        if defaults.object(forKey: "speechPitch") != nil {
            speechPitch = defaults.double(forKey: "speechPitch")
        }

        // Stage the persisted "share device info" choice on the core before the
        // first connect. The assignment above doesn't fire didSet (init), so push
        // it explicitly — otherwise the core would keep its own ON default and a
        // saved opt-out wouldn't survive a relaunch.
        shareClientContext = clientContextPrefs.isEnabled
        core.setShareClientContext(shareClientContext)

        // Claim this client's own MCP surface before the first connect. The core
        // is shared with adele-kde and defaults to `kde`, so without this the Mac
        // resolves its client MCP servers — and its built-in opt-outs — from
        // KDE's section of client-mcp.toml.
        core.setMcpSurface(AdeleCore.macMcpSurface)
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
        drafts.forget(id)  // its draft goes with it (#7)
        if selectedConversationID == id {
            selectedConversationID = nil
            messages = []
        }
    }

    // Rename / archive / unarchive (daemon refreshes the sidebar via the reducer).
    func renameConversation(_ id: String, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { try? await core.renameConversation(id: id, title: trimmed) }
    }

    func archiveConversation(_ id: String) {
        Task { try? await core.archiveConversation(id: id) }
    }

    func unarchiveConversation(_ id: String) {
        Task { try? await core.unarchiveConversation(id: id) }
    }

    var activeConversations: [ConversationSummary] { conversations.filter { !$0.archived } }
    var archivedConversations: [ConversationSummary] { conversations.filter(\.archived) }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Deliberately NOT gated on `sendEnabled`: while a reply streams the core
        // QUEUES the submit rather than refusing it (#1), so the composer must
        // stay live. `sendEnabled` now only dims the button's affordance.
        guard !text.isEmpty else { return }
        // Clear only THIS conversation's draft — a send never touches another's.
        drafts.clear(selectedConversationID)
        core.sendPrompt(text)
    }

    // MARK: - Message queue (#1)

    /// Check a queued chip out into the composer for editing. `visibleIndex` is
    /// the chip's rendered position; the reducer indexes the full queue.
    func editQueued(visible visibleIndex: Int) {
        core.editQueued(queued.fullIndex(forVisible: visibleIndex))
    }

    /// Drop a queued chip without sending it (`RemoveQueued` takes the rendered
    /// position verbatim).
    func removeQueued(visible visibleIndex: Int) {
        core.removeQueued(visibleIndex)
    }

    func cancelQueuedEdit() {
        core.cancelQueuedEdit()
    }

    /// Handle a queue-navigation key pressed in the composer. Returns `true` when
    /// the key was consumed as a queue action, `false` to let it keep its default
    /// caret behaviour.
    func handleRecallKey(_ key: RecallKey) -> Bool {
        switch queued.decision(for: key, composerEmpty: draft.isEmpty) {
        case .recall(let index):
            core.editQueued(index)
            return true
        case .cancel:
            core.cancelQueuedEdit()
            return true
        case .proceed:
            return false
        }
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

    /// Reflect the `You:` (voice-input) state for the open conversation.
    func setVoiceIn(_ enabled: Bool) {
        guard let id = selectedConversationID else { return }
        core.setVoiceIn(conversationID: id, enabled: enabled)
    }

    /// Speak a sample line with the current voice settings (Voice settings preview).
    func previewVoice() {
        speaker.stop()
        speaker.speak("Hi, I'm Adele — this is how I sound.",
                      voiceIdentifier: voiceIdentifier, rate: Float(speechRate), pitch: Float(speechPitch))
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

    /// The daemon's last reported binding for `kind`, if it has one.
    func purpose(for kind: String) -> PurposeConfigView? {
        switch kind {
        case "interactive": return purposes.interactive
        case "dreaming": return purposes.dreaming
        case "consolidation": return purposes.consolidation
        case "embedding": return purposes.embedding
        case "titling": return purposes.titling
        case "voice": return purposes.voice
        default: return nil
        }
    }

    /// Assign a purpose (e.g. "interactive") to a model. Reloads purposes after.
    ///
    /// Every write goes through `PurposeWrite.planned`, which drops anything the
    /// UI could not honestly have displayed (an unloaded model list, a mixed
    /// `"primary"` pair) and anything equal to what the daemon already reports.
    /// The latter is what keeps a refresh-then-reconcile from writing: see
    /// adele-gtk#142, where that loop ran at ~3 writes/sec until the socket
    /// dropped. `SetPurpose` is a full replace, so the fields this UI does not
    /// edit are carried off the last reported binding rather than cleared.
    func setPurpose(_ purpose: String, connectionID: String, modelID: String) {
        let lastKnown = self.purpose(for: purpose)
        guard let config = PurposeWrite.planned(
            purpose: purpose,
            selection: PurposeSelection(
                pick: (connection: connectionID, model: modelID),
                carryingFrom: lastKnown
            ),
            lastKnown: lastKnown
        ) else { return }
        Task {
            do {
                try await core.setPurpose(purpose, config: config)
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
        Self.groupByConnection(models)
    }

    /// The model picker's grouped list, after the select-models filter.
    var pickerModelsByConnection: [(label: String, listings: [ModelListing])] {
        Self.groupByConnection(pickerModels)
    }

    private static func groupByConnection(
        _ listings: [ModelListing]
    ) -> [(label: String, listings: [ModelListing])] {
        var order: [String] = []
        var groups: [String: (label: String, listings: [ModelListing])] = [:]
        for listing in listings {
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
                DisplayMessage(id: $0.id, role: $0.role, content: $0.content, kind: $0.kind)
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
            knowledgeMaintenanceTaskCompleted(id)

        case .taskLogs(let id, let entries):
            taskLogs[id] = entries

        case .scratchpad(let notes):
            scratchpad = notes

        case .knowledgeChanged:
            knowledgeChanged()

        case .addUserMessage(let content):
            // Exactly one bubble per send (#8): the core emits this once per
            // `SendPrompt` effect — for a direct send and for a queue flush (one
            // combined turn) alike — and its reducer swallows the daemon's echoed
            // `UserMessageAdded` by idempotency key. Never append a bubble here
            // from `send()` as well, or the turn draws twice.
            appendUser(content)

        case .composerText(let text):
            // The reducer drives the composer for queue operations: a recalled
            // message loads here, and an enqueue / cancelled edit clears it. Only
            // ever the OPEN conversation's draft.
            drafts[selectedConversationID] = text

        case .queuedMessages(let messages, let editing):
            queued = QueuedMessagesState(messages: messages, editing: editing)

        case .chunk(let text):
            appendChunk(text)

        case .complete(let text):
            completeStreaming(text)

        case .speak(let text):
            speaker.speak(text, voiceIdentifier: voiceIdentifier, rate: Float(speechRate), pitch: Float(speechPitch))

        case .adeleOutputDropdown(let level):
            adeleOutputLevel = level

        case .toast(let text):
            showToast(text)

        case .inlineNote(let text):
            // The FFI stringifies the note's `MessageKind` into the text (the
            // KDE-era interim presentation); split it back off so the badge — not
            // a text marker — carries it.
            let note = MessageKind.fromInlineNote(text)
            messages.append(
                DisplayMessage(id: freshID(), role: "note", content: note.content, kind: note.kind)
            )

        case .unknown:
            break
        }
    }

    func showToast(_ text: String) {
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
