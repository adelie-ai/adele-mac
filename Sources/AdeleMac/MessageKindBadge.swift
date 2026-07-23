import AdeleCore
import SwiftUI

/// A subtle marker for the two client-tagged transcript lines (voice#126):
/// `.spoken` — a `say_this` Adele voiced aloud — and `.speechDisabled` — a
/// `say_this` shown but not spoken because voice output is off. `.normal`
/// messages, which is nearly all of them, render nothing at all.
///
/// The badge is deliberately quiet: caption-sized, secondary, capsule-tinted, so
/// it reads as an annotation on the turn rather than another bubble.
struct MessageKindBadge: View {
    let kind: MessageKind

    private var symbol: String {
        kind == .spoken ? "speaker.wave.2.fill" : "speaker.slash.fill"
    }

    var body: some View {
        if let label = kind.badgeLabel {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                Text(label)
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(kind.accessibilityDescription ?? label)
        }
    }
}

extension View {
    /// Stack a `MessageKindBadge` above this view for a `.spoken` /
    /// `.speechDisabled` message. A `.normal` message returns `self` unchanged —
    /// no badge, and no extra container in the transcript's layout.
    @ViewBuilder
    func messageKindBadge(
        _ kind: MessageKind,
        alignment: HorizontalAlignment = .leading
    ) -> some View {
        if kind == .normal {
            self
        } else {
            VStack(alignment: alignment, spacing: 3) {
                MessageKindBadge(kind: kind)
                self
            }
        }
    }
}
