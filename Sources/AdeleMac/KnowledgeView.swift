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
/// entries over the management bridge; add/edit/delete via the editor sheet;
/// on-demand maintenance passes via the toolbar's Maintenance menu (tracked in
/// the tasks panel, not here). The list refetches itself on `knowledge_changed`,
/// so a maintenance pass — or an edit made from another client — lands live.
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
                ToolbarItem(placement: .automatic) {
                    KnowledgeMaintenanceMenu()
                        .environment(model)
                }
            }
        }
        .frame(width: 580, height: 540)
        .sheet(item: $editor) { target in
            KnowledgeEditor(target: target)
                .environment(model)
        }
        // `model.showKnowledge` (this sheet's presentation binding) is what gates
        // the debounced `knowledge_changed` refetch, so nothing extra is needed
        // here to keep the list live.
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
            KnowledgeTagChips(entry: entry)
        }
        .padding(.vertical, 3)
    }
}

private struct KnowledgeEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: EditorTarget

    @State private var content = ""
    // Tags are edited one level at a time (kind vs facet) and rejoined —
    // normalized — on save.
    @State private var kindsText = ""
    @State private var facetsText = ""

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
            KnowledgeTagFields(kindsText: $kindsText, facetsText: $facetsText)
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
        .frame(width: 480, height: 380)
        .onAppear {
            if case .existing(let entry) = target {
                content = entry.content
                (kindsText, facetsText) = entry.tagFields
            }
        }
    }

    private var parsedTags: [String] {
        KnowledgeTag.combine(kinds: kindsText, facets: facetsText)
    }
}
