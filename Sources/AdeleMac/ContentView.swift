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
        .adeleToasts()
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
    @State private var showToolUsage = false

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
                if model.selectedConversationID != nil {
                    ToolGateToggle()
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if model.selectedConversationID != nil {
                    Button {
                        showToolUsage = true
                    } label: {
                        Label("Tool cost", systemImage: "chart.bar.xaxis")
                    }
                    .help("What this conversation's tools cost it")
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
        .sheet(isPresented: $showToolUsage) {
            if let id = model.selectedConversationID {
                ToolUsageView(conversationID: id)
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
    /// The live dictation session: the text each transcript is written on top of,
    /// the transcript itself, and the conversation the session started in.
    ///
    /// An object, not view state. The recognizer's callbacks outlive this draw of
    /// the composer, so they must read the session as it is now rather than as a
    /// captured copy of the view saw it. The reference never changes, so the
    /// question does not arise.
    @State private var session = DictationSession()
    /// Typing waiting to be adopted, once the person stops for a moment.
    ///
    /// Non-nil means the composer holds text the session has not taken as its
    /// base yet, so the transcript must not be written over it.
    @State private var pendingRebase: Task<Void, Never>?

    /// How long the composer waits for typing to stop before it adopts what was
    /// typed. Longer than the gap between two keystrokes, and short enough that
    /// the words spoken next still land after the typed text.
    private static let typingQuietPeriod = Duration.milliseconds(500)

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            // Messages queued while a reply streams (#1), above the live composer.
            QueuedChipsView()
            composer
        }
        .onChange(of: model.selectedConversationID) { _, _ in
            // The composer, its draft and the voice-input flag all belong to the
            // selected conversation, and this view survives the switch. A session
            // left running would write what is said next into the conversation
            // now open, over a draft it never touched. What was dictated stays in
            // the draft of the conversation it was dictated into (#7).
            stopDictation()
        }
        .onDisappear {
            // The composer is drawn only while a conversation is open, so
            // deleting that conversation or switching connection profile removes
            // this view outright. A removed view's body is not evaluated again,
            // so the change of selected conversation above never reaches it, and
            // the session would outlive the composer: the voice-input flag would
            // stay set on a conversation with no microphone behind it, and the
            // recognition task would run to its own end (#48).
            stopDictation()
        }
        .onChange(of: model.composerWritesFromCore) { _, _ in
            // A recalled queued message and a prompt restored after a failure
            // each arrive as one event carrying the whole text. There is no
            // burst to wait out, and the words are needed as the base before the
            // next transcript lands, so they rebase at once (#47).
            rebaseNow()
        }
        .onChange(of: model.draft) { _, text in
            scheduleRebase(for: text)
        }
        .onChange(of: model.dictationIdleSettings) { _, _ in
            // A setting changed mid-session must not fire against quiet that was
            // already banked: turning "send after a pause" on after twenty
            // seconds of silence must not send at once.
            guard isDictating else { return }
            session.restartSilenceClock(at: SuspendingClock.now)
        }
        .alert("Dictation", isPresented: Binding(
            get: { dictationError != nil },
            set: { if !$0 { dictationError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(dictationError ?? "")
        }
        // The silence clock, running only while the mic is on. Restarted by the
        // `id`, so switching dictation off cancels it (#43).
        .task(id: isDictating) {
            while isDictating && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                applyIdleAction()
            }
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
                    send()
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
            // Stop the running turn (#22). Present only while the core reports a
            // handle, and beside Send rather than in place of it — a message
            // typed mid-reply is QUEUED (#1), so cancelling must not be the only
            // way to act on a turn that is taking too long.
            if model.turn.canCancel {
                Button {
                    model.cancelTurn()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Stop this reply")
            }
            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
            }
            .buttonStyle(.plain)
            // Only the empty-draft gate: `sendEnabled` is false while a reply
            // streams, but a send then QUEUES rather than being refused (#1), so
            // the control must stay live.
            .disabled(promptToSend(draft: model.draft) == nil)
            .help(model.sendEnabled ? "Send" : "Queue this message (a reply is still streaming)")
        }
        .padding(12)
    }

    /// Send the composer, and start the dictation transcript over.
    ///
    /// The recognizer holds every word since its task began, so a send has to
    /// consume the transcript as well as the text. Without this the next
    /// transcript arrives carrying the words just sent and writes them back into
    /// the cleared composer (adele-mac#42). The microphone keeps running, so
    /// dictating several messages in a row works.
    ///
    /// Only a send that happened resets anything. Return pressed on an empty or
    /// whitespace-only composer sends nothing, and a reset there would cancel a
    /// spoken sentence out of the recognizer that no one ever received - the
    /// case where Return arrives in the beat before the first partial.
    private func send() {
        guard model.send() else { return }
        session.consumeOnSend(at: SuspendingClock.now)
        dictation.restart()
    }

    /// Take composer text that dictation did not write as the session's new base.
    ///
    /// A queued message recalled with Up (which takes it out of the queue, so it
    /// exists nowhere else), a failed prompt offered back, and text typed by hand
    /// all arrive this way. The transcript would otherwise be written over the
    /// top of them at the next partial. The recognizer restarts as well: it still
    /// holds the words the new base now carries, and they would land twice.
    private func adoptExternalComposerText(_ text: String) {
        guard isDictating, session.conversationID == model.selectedConversationID else { return }
        guard session.rebaseIfExternal(composer: text) else { return }
        dictation.restart()
    }

    /// Wait for typing to stop, then adopt what was typed.
    ///
    /// A rebase has to restart the recognizer, because the transcript is
    /// cumulative: the running task still holds the words the new base carries,
    /// and they would land a second time. One restart per keystroke drops the
    /// audio around each one and spends a recognition request on each one, so a
    /// typed sentence spends about forty of them and dictation is dead while the
    /// person types (#47). Waiting for the keyboard to go quiet turns a burst of
    /// keystrokes into one rebase.
    private func scheduleRebase(for text: String) {
        guard isDictating, session.conversationID == model.selectedConversationID else { return }
        // The session's own transcripts come through here too, and they are not
        // external text.
        guard text != session.composerText else { return }
        pendingRebase?.cancel()
        pendingRebase = Task {
            try? await Task.sleep(for: Self.typingQuietPeriod)
            guard !Task.isCancelled else { return }
            pendingRebase = nil
            // The draft as it reads now, not as it read when the burst started:
            // everything typed since is part of the same base.
            adoptExternalComposerText(model.draft)
        }
    }

    /// Adopt the composer text now, dropping any wait for typing to stop.
    private func rebaseNow() {
        pendingRebase?.cancel()
        pendingRebase = nil
        adoptExternalComposerText(model.draft)
    }

    /// Stop a running session. `Dictation` reports the end through `onEnd`, which
    /// clears the button, the flag and the session.
    private func stopDictation() {
        pendingRebase?.cancel()
        pendingRebase = nil
        guard isDictating else { return }
        dictation.stop()
    }

    /// Apply whichever silence timer has come due (#43).
    ///
    /// Driven by a tick while dictating rather than by a scheduled deadline, so
    /// a changed setting takes effect at once and no timer has to be cancelled
    /// and rebuilt on every transcript.
    private func applyIdleAction() {
        guard isDictating else { return }
        switch dictationIdleAction(
            silence: session.silence(now: SuspendingClock.now),
            hasTranscript: session.hasTranscript,
            settings: model.dictationIdleSettings
        ) {
        case .none:
            return
        case .send:
            send()
        case .stopListening:
            stopDictation()
        }
    }

    private func toggleDictation() {
        if isDictating {
            stopDictation()
            return
        }
        Task {
            guard await dictation.requestAuthorization() else {
                dictationError = "Microphone and Speech Recognition permission are required. Grant them in System Settings → Privacy & Security."
                return
            }
            // Dictation adds to the composer rather than taking it over: each
            // transcript replaces the one before it, on top of whatever was in
            // the composer when the session started.
            session.begin(
                base: model.draft,
                conversationID: model.selectedConversationID,
                at: SuspendingClock.now
            )
            // Written to the session's own conversation, never to the selected
            // one: a transcript that arrives in the moment between a conversation
            // switch and the session ending belongs to the conversation it was
            // spoken into.
            dictation.onText = { text in
                let composer = session.receive(transcript: text, at: SuspendingClock.now)
                // Typing that is still waiting to be adopted owns the composer.
                // This transcript sits on a base from before it, so writing it
                // now would delete the characters just typed; the rebase takes
                // them as the new base instead, and drops this transcript.
                guard pendingRebase == nil else { return }
                model.drafts[session.conversationID] = composer
            }
            dictation.onRollover = {
                // One recognition task hit the framework's limit and another
                // took its place. The words heard so far move into the base,
                // where the new task's transcript adds to them rather than
                // replacing them.
                session.commitOnTaskRollover()
            }
            dictation.onEnd = { error in
                isDictating = false
                pendingRebase?.cancel()
                pendingRebase = nil
                model.setVoiceIn(false, conversationID: session.conversationID)
                session.end()
                if let error { dictationError = error }
            }
            isDictating = true
            model.setVoiceIn(true, conversationID: session.conversationID)
            dictation.start()
        }
    }
}
