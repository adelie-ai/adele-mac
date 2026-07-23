import AdeleCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.connected {
                ChatSplitView()
            } else {
                ConnectView()
            }
        }
        .overlay(alignment: .top) {
            if let toast = model.toast {
                Text(toast)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.separator))
                    .shadow(radius: 8, y: 4)
                    .padding(.top, 12)
                    .frame(maxWidth: 420)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: model.toast)
        .onAppear { model.autoReconnect() }
    }
}

// MARK: - Connect gate

private struct ConnectView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
            Text("Connect to Adele")
                .font(.title2.weight(.semibold))

            if !model.profiles.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Saved connections")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(model.profiles) { profile in
                        Button {
                            model.connect(using: profile)
                        } label: {
                            HStack {
                                Image(systemName: "network")
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(profile.name)
                                    Text(profile.wsURL).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        .contextMenu {
                            Button("Delete", role: .destructive) { model.deleteProfile(profile) }
                        }
                    }
                }
                .frame(maxWidth: 360)
                Text("or connect manually")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Enter the WebSocket address of a running desktop-assistant daemon.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 8) {
                TextField("ws://host:port/ws", text: $model.serverAddress)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.connect() }
                HStack(spacing: 8) {
                    TextField("Username", text: $model.username)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Password", text: $model.password)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.connect() }
                }
                Button(model.connecting ? "Connecting…" : "Connect") {
                    model.connect()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.connecting || model.serverAddress.isEmpty)
            }
            .frame(maxWidth: 360)

            if let error = model.connectionError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Main split

private struct ChatSplitView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingDelete: ConversationSummary?
    @State private var renameTarget: ConversationSummary?
    @State private var renameText = ""

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: Binding(
                get: { model.selectedConversationID },
                set: { if let id = $0 { model.selectConversation(id) } }
            )) {
                ForEach(model.activeConversations) { convo in
                    conversationRow(convo)
                }
                if !model.archivedConversations.isEmpty {
                    Section("Archived") {
                        ForEach(model.archivedConversations) { convo in
                            conversationRow(convo)
                        }
                    }
                }
            }
            .navigationTitle("Conversations")
            .navigationSplitViewColumnWidth(min: 200, ideal: 260)
        } detail: {
            ChatPane()
        }
        .alert("Rename Conversation", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        ), presenting: renameTarget) { convo in
            TextField("Title", text: $renameText)
            Button("Rename") { model.renameConversation(convo.id, title: renameText) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete this conversation?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { convo in
            Button("Delete", role: .destructive) { model.deleteConversation(convo.id) }
            Button("Cancel", role: .cancel) {}
        } message: { convo in
            Text(convo.title.isEmpty ? "New Conversation" : convo.title)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if model.profiles.count > 1 || model.currentProfile != nil {
                    Menu {
                        ForEach(model.profiles) { profile in
                            Button {
                                model.switchProfile(profile)
                            } label: {
                                if profile.id == model.currentProfileID {
                                    Label(profile.name, systemImage: "checkmark")
                                } else {
                                    Text(profile.name)
                                }
                            }
                        }
                    } label: {
                        Label(model.currentProfile?.name ?? "Connection", systemImage: "network")
                    }
                    .help("Switch connection")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showKnowledge = true
                } label: {
                    Label("Knowledge Base", systemImage: "books.vertical")
                }
                .help("Knowledge base")
            }
            ToolbarItem(placement: .primaryAction) {
                TasksButton()
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.newConversation()
                } label: {
                    Label("New Conversation", systemImage: "square.and.pencil")
                }
            }
        }
        .sheet(isPresented: $model.showKnowledge) {
            KnowledgeView()
        }
    }

    @ViewBuilder
    private func conversationRow(_ convo: ConversationSummary) -> some View {
        ConversationRow(convo: convo)
            .tag(convo.id)
            .contextMenu {
                Button("Rename…") {
                    renameText = convo.title
                    renameTarget = convo
                }
                if convo.archived {
                    Button("Unarchive") { model.unarchiveConversation(convo.id) }
                } else {
                    Button("Archive") { model.archiveConversation(convo.id) }
                }
                Button("Delete", role: .destructive) { pendingDelete = convo }
            }
    }
}

private struct ConversationRow: View {
    let convo: ConversationSummary

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(convo.title.isEmpty ? "New Conversation" : convo.title)
                    .lineLimit(1)
                Text("^[\(convo.messageCount) message](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Chat pane

private struct ChatPane: View {
    @Environment(AppModel.self) private var model
    @State private var showPersonality = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if model.selectedConversationID == nil {
                ContentUnavailableView(
                    "No Conversation",
                    systemImage: "bubble.left",
                    description: Text("Select a conversation or start a new one.")
                )
            } else {
                TranscriptView()
                Divider()
                ComposerView()
            }
        }
        .navigationTitle("Adele")
        .inspector(isPresented: $model.showScratchpad) {
            ScratchpadView()
                .inspectorColumnWidth(min: 220, ideal: 280)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                if model.selectedConversationID != nil, !model.models.isEmpty {
                    ModelPicker()
                }
            }
            ToolbarItem(placement: .status) {
                if let usage = model.contextUsage {
                    ContextUsageReadout(usage: usage)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if model.selectedConversationID != nil {
                    VoiceOutputMenu()
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if model.selectedConversationID != nil {
                    Button {
                        showPersonality = true
                    } label: {
                        Label("Personality", systemImage: "theatermasks")
                    }
                    .help("Personality for this conversation")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showScratchpad.toggle()
                } label: {
                    Label("Scratchpad", systemImage: "note.text")
                }
                .help("Show scratchpad")
            }
        }
        .sheet(isPresented: $showPersonality) {
            if let id = model.selectedConversationID {
                ConversationPersonalitySheet(conversationID: id)
            }
        }
    }
}

private struct VoiceOutputMenu: View {
    @Environment(AppModel.self) private var model

    private var icon: String {
        model.adeleOutputLevel == "disabled" ? "speaker.slash" : "speaker.wave.2"
    }

    var body: some View {
        Menu {
            Picker("Adele speaks", selection: Binding(
                get: { model.adeleOutputLevel },
                set: { model.setAdeleOutput($0) }
            )) {
                Text("Off").tag("disabled")
                Text("On Demand").tag("on_demand")
                Text("Always").tag("always")
            }
            .pickerStyle(.inline)
            Divider()
            Button("Stop Speaking") { model.stopSpeaking() }
        } label: {
            Label("Voice", systemImage: icon)
        }
        .help("Spoken replies")
    }
}

private struct ModelPicker: View {
    @Environment(AppModel.self) private var model
    @State private var showSelectModels = false

    var body: some View {
        Menu {
            ForEach(model.pickerModelsByConnection, id: \.label) { group in
                Section(group.label) {
                    ForEach(group.listings) { listing in
                        Button {
                            model.selectModel(listing)
                        } label: {
                            if model.isSelected(listing) {
                                Label(listing.model.displayName, systemImage: "checkmark")
                            } else {
                                Text(listing.model.displayName)
                            }
                        }
                    }
                }
            }
            if let selected = model.selectedListing, selected.model.capabilities.reasoning {
                Divider()
                Menu("Reasoning Effort") {
                    ForEach(["low", "medium", "high"], id: \.self) { level in
                        Button(level.capitalized) {
                            model.selectModel(selected, effort: level)
                        }
                    }
                    Button("Default") { model.selectModel(selected) }
                }
            }
            Divider()
            Button("Use Default Model") { model.clearModelOverride() }
            Button("Select Models…") { showSelectModels = true }
        } label: {
            Label(model.currentModelLabel, systemImage: "cpu")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .sheet(isPresented: $showSelectModels, onDismiss: { model.reloadSelectedModels() }) {
            SelectModelsView()
        }
    }
}

private struct ContextUsageReadout: View {
    let usage: ContextUsage

    private var color: Color {
        switch usage.level {
        case "red": return .red
        case "amber": return .orange
        default: return .green
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(usage.readout)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help("Context window usage")
    }
}

private struct TranscriptView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    if let status = model.chatStatus {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(status).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .id("chat-status")
                    }
                }
                .padding(16)
            }
            .onChange(of: model.messages.last?.content) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: model.chatStatus) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            if model.chatStatus != nil {
                proxy.scrollTo("chat-status", anchor: .bottom)
            } else if let last = model.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

private struct MessageBubble: View {
    let message: DisplayMessage

    var body: some View {
        if message.isNote {
            Text(message.content)
                .font(.callout)
                .italic()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 2)
                .messageKindBadge(message.kind, alignment: .center)
        } else {
            bubble
        }
    }

    private var bubble: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.isUser {
                Spacer(minLength: 40)
                bubbleContent
                avatar
            } else {
                avatar
                bubbleContent
                Spacer(minLength: 40)
            }
        }
    }

    private var avatar: some View {
        Image(systemName: message.isUser ? "person.crop.circle.fill" : "sparkle")
            .font(.system(size: 15))
            .foregroundStyle(message.isUser ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .frame(width: 22, height: 22)
            .padding(.top, 4)
            .accessibilityHidden(true)
    }

    private var bubbleContent: some View {
        Group {
            if message.isUser {
                Text(message.content).textSelection(.enabled)
            } else if message.content.isEmpty && message.streaming {
                Text("…").foregroundStyle(.secondary)
            } else {
                MarkdownView(text: message.content)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            message.isUser ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .foregroundStyle(message.isUser ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .messageKindBadge(message.kind, alignment: message.isUser ? .trailing : .leading)
    }
}

private struct ComposerView: View {
    @Environment(AppModel.self) private var model
    @State private var dictation = Dictation()
    @State private var isDictating = false
    @State private var dictationError: String?

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            // Messages queued while a reply streams (#1), above the live composer.
            QueuedChipsView()
            composer
        }
        .alert("Dictation", isPresented: Binding(
            get: { dictationError != nil },
            set: { if !$0 { dictationError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(dictationError ?? "")
        }
    }

    private var composer: some View {
        @Bindable var model = model
        return HStack(alignment: .bottom, spacing: 8) {
            TextField("Message Adele…", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onKeyPress(keys: [.return]) { press in
                    // Return sends; Shift+Return inserts a newline. Never gated on
                    // the streaming state — a send mid-reply is QUEUED (#1).
                    if press.modifiers.contains(.shift) { return .ignored }
                    model.send()
                    return .handled
                }
                .onKeyPress(keys: [.upArrow, .downArrow, .escape]) { press in
                    // Walk the message queue: Up on an empty composer recalls the
                    // last queued message, Down steps back out, Esc abandons the
                    // edit. Anything else keeps its default caret behaviour.
                    let key: RecallKey
                    switch press.key {
                    case .upArrow: key = .up
                    case .downArrow: key = .down
                    default: key = .escape
                    }
                    return model.handleRecallKey(key) ? .handled : .ignored
                }
            Button {
                toggleDictation()
            } label: {
                Image(systemName: isDictating ? "mic.fill" : "mic")
                    .font(.system(size: 20))
                    .foregroundStyle(isDictating ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .symbolEffect(.pulse, isActive: isDictating)
            }
            .buttonStyle(.plain)
            .help(isDictating ? "Stop dictation" : "Dictate")
            Button {
                model.send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
            }
            .buttonStyle(.plain)
            // Only the empty-draft gate: `sendEnabled` is false while a reply
            // streams, but a send then QUEUES rather than being refused (#1), so
            // the control must stay live.
            .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help(model.sendEnabled ? "Send" : "Queue this message (a reply is still streaming)")
        }
        .padding(12)
    }

    private func toggleDictation() {
        if isDictating {
            dictation.stop()
            return
        }
        Task {
            guard await dictation.requestAuthorization() else {
                dictationError = "Microphone and Speech Recognition permission are required. Grant them in System Settings → Privacy & Security."
                return
            }
            dictation.onText = { model.draft = $0 }  // stream into the composer
            dictation.onEnd = { error in
                isDictating = false
                model.setVoiceIn(false)
                if let error { dictationError = error }
            }
            isDictating = true
            model.setVoiceIn(true)
            dictation.start()
        }
    }
}
