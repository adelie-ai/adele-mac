import AdeleCore
import SwiftUI

/// The strip of queued-message chips shown just above the composer (#1).
///
/// While a reply streams, submits are queued by the core rather than refused;
/// each queued message gets a chip with an *edit* affordance (checks it back out
/// into the composer) and a *remove* affordance (drops it unsent), alongside an
/// "N queued" indicator. Hidden entirely when nothing is queued and nothing is
/// checked out.
struct QueuedChipsView: View {
    @Environment(AppModel.self) private var model

    /// Visible while anything is queued, and while a message is checked out for
    /// editing (so the cancel affordance stays reachable even when it was the
    /// only queued message).
    private var isVisible: Bool { !model.queued.isEmpty || model.queued.isEditing }

    var body: some View {
        if isVisible {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    Text(model.queued.indicator ?? "Editing queued message")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .help("Queued messages send as one turn when the reply finishes")
                    ForEach(model.queued.chips) { chip in
                        QueuedChipView(chip: chip)
                    }
                    if model.queued.isEditing {
                        Button("Cancel Edit") { model.cancelQueuedEdit() }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Return the recalled message to the queue (Esc)")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            .scrollIndicators(.never)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(model.queued.indicator ?? "Editing queued message")
        }
    }
}

private struct QueuedChipView: View {
    @Environment(AppModel.self) private var model
    let chip: QueuedChip

    var body: some View {
        HStack(spacing: 4) {
            Button {
                model.editQueued(visible: chip.id)
            } label: {
                Text(chip.preview)
                    .font(.caption)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Edit “\(chip.text)”")
            .accessibilityLabel("Edit queued message \(chip.id + 1)")

            Button {
                model.removeQueued(visible: chip.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove this queued message")
            .accessibilityLabel("Remove queued message \(chip.id + 1)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
    }
}
