import AdeleCore
import SwiftUI

/// Read-only scratchpad inspector: the per-conversation working notes Adele
/// maintains. The FFI exposes no scratchpad-edit intent, so this is display-only
/// (todos still show their checked state).
struct ScratchpadView: View {
    @Environment(AppModel.self) private var model

    private var grouped: [(type: String, notes: [ScratchpadNote])] {
        var order: [String] = []
        var groups: [String: [ScratchpadNote]] = [:]
        for note in model.scratchpad {
            if groups[note.noteType] == nil {
                order.append(note.noteType)
                groups[note.noteType] = []
            }
            groups[note.noteType]?.append(note)
        }
        return order.map { type in
            let notes = (groups[type] ?? []).sorted {
                ($0.sequence ?? .max, $0.key) < ($1.sequence ?? .max, $1.key)
            }
            return (type, notes)
        }
    }

    var body: some View {
        Group {
            if model.scratchpad.isEmpty {
                ContentUnavailableView(
                    "Scratchpad Empty",
                    systemImage: "note.text",
                    description: Text("Notes Adele keeps for this conversation appear here.")
                )
            } else {
                List {
                    ForEach(grouped, id: \.type) { group in
                        Section(group.type.capitalized) {
                            ForEach(group.notes) { note in
                                ScratchpadRow(note: note)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Scratchpad")
    }
}

private struct ScratchpadRow: View {
    let note: ScratchpadNote

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if note.noteType == "todo" {
                Image(systemName: note.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(note.done ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            }
            VStack(alignment: .leading, spacing: 2) {
                if !note.key.isEmpty {
                    Text(note.key)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(note.content)
                    .font(.callout)
                    .strikethrough(note.done)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 1)
    }
}
