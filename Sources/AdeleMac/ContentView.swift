import AdeleCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.connected {
            ChatSplitView()
        } else {
            ConnectView()
        }
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
            Text("Enter the WebSocket address of a running desktop-assistant daemon.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

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

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: Binding(
                get: { model.selectedConversationID },
                set: { if let id = $0 { model.selectConversation(id) } }
            )) {
                ForEach(model.conversations) { convo in
                    ConversationRow(convo: convo)
                        .tag(convo.id)
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                model.deleteConversation(convo.id)
                            }
                        }
                }
            }
            .navigationTitle("Conversations")
            .navigationSplitViewColumnWidth(min: 200, ideal: 260)
        } detail: {
            ChatPane()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.newConversation()
                } label: {
                    Label("New Conversation", systemImage: "square.and.pencil")
                }
            }
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

    var body: some View {
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
        .toolbar {
            ToolbarItem(placement: .status) {
                if let readout = model.contextReadout {
                    Text(readout)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
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
        HStack {
            if message.isUser { Spacer(minLength: 40) }
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
            if !message.isUser { Spacer(minLength: 40) }
        }
    }
}

private struct ComposerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message Adele…", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onSubmit { model.send() }
            Button {
                model.send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
            }
            .buttonStyle(.plain)
            .disabled(!model.sendEnabled || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
    }
}
