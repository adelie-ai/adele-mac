import AdeleCore
import SwiftUI

private enum EditorTarget: Identifiable {
    case new
    case existing(KnowledgeEntry)
    var id: String {
        switch self {
        case .new: return "new"
        case .existing(let entry): return entry.id
        }
    }
}

/// Knowledge-base browser/editor, presented as a sheet. Lists and searches
/// entries over the management bridge; add/edit/delete via the editor sheet.
struct KnowledgeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var editor: EditorTarget?

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            VStack(spacing: 0) {
                if let error = model.settingsError {
                    Text(error).font(.caption).foregroundStyle(.red).padding(6)
                }
                List {
                    if model.knowledgeEntries.isEmpty {
                        Text(model.knowledgeLoading ? "Loading…" : "No entries.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.knowledgeEntries) { entry in
                            Button { editor = .existing(entry) } label: {
                                KnowledgeRow(entry: entry)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Edit") { editor = .existing(entry) }
                                Button("Delete", role: .destructive) { model.deleteKnowledge(id: entry.id) }
                            }
                        }
                    }
                }
            }
            .searchable(text: $model.knowledgeSearch, prompt: "Search knowledge")
            .onSubmit(of: .search) { model.loadKnowledge() }
            .navigationTitle("Knowledge Base")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { editor = .new } label: { Image(systemName: "plus") }
                        .help("New entry")
                }
            }
        }
        .frame(width: 580, height: 540)
        .sheet(item: $editor) { target in
            KnowledgeEditor(target: target)
                .environment(model)
        }
        .task { model.loadKnowledge() }
    }
}

private struct KnowledgeRow: View {
    let entry: KnowledgeEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.content)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !entry.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(entry.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }
}

private struct KnowledgeEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: EditorTarget

    @State private var content = ""
    @State private var tagsText = ""

    private var existingID: String? {
        if case .existing(let entry) = target { return entry.id }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(existingID == nil ? "New Entry" : "Edit Entry")
                .font(.headline)
            TextEditor(text: $content)
                .font(.body)
                .frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            TextField("Tags (comma-separated)", text: $tagsText)
                .textFieldStyle(.roundedBorder)
            HStack {
                if let id = existingID {
                    Button("Delete", role: .destructive) {
                        model.deleteKnowledge(id: id)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    model.saveKnowledge(id: existingID, content: content, tags: parsedTags)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 480, height: 360)
        .onAppear {
            if case .existing(let entry) = target {
                content = entry.content
                tagsText = entry.tags.joined(separator: ", ")
            }
        }
    }

    private var parsedTags: [String] {
        tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
