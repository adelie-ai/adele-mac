import Foundation

/// One rendered chip in the queued-messages strip.
///
/// `id` is the message's position in the *rendered* list, which is what
/// `RemoveQueued` takes verbatim; `EditQueued` needs the full-queue index (see
/// ``QueuedMessagesState/fullIndex(forVisible:)``).
public struct QueuedChip: Identifiable, Hashable, Sendable {
    public let id: Int
    public let text: String
    public let preview: String
}

/// A queue-navigation key pressed in the composer.
public enum RecallKey: Sendable {
    case up
    case down
    case escape
}

/// What a queue-navigation key should do given the current queue/edit state.
public enum RecallDecision: Equatable, Sendable {
    /// Check out the queued message at this FULL-queue index (`EditQueued`).
    case recall(Int)
    /// Abandon the in-progress edit (`CancelQueuedEdit`).
    case cancel
    /// Not a queue action — let the key keep its default caret behaviour.
    case proceed
}

/// The render-ready snapshot of the open conversation's message queue, mirroring
/// the core's `queued_messages` view-event (#1).
///
/// The reducer owns all queueing logic; this type is pure presentation state
/// plus the small index/keyboard arithmetic the view needs, kept out of the
/// SwiftUI views so it is unit-testable. It mirrors the GTK client's
/// `compose_status` / `chip_preview` / `chip_edit_index` / `recall_decision`.
///
/// Note that a message checked out for editing is *absent* from `messages` — the
/// reducer removed it from the outbox and remembers the slot it will be
/// reinserted at in `editing`.
public struct QueuedMessagesState: Equatable, Sendable {
    /// Queued messages in submit order, excluding any checked-out for editing.
    public var messages: [String]
    /// The full-queue slot of the message currently checked out into the
    /// composer, or `nil` when composing fresh.
    public var editing: Int?

    public init(messages: [String] = [], editing: Int? = nil) {
        self.messages = messages
        self.editing = editing
    }

    /// Maximum characters shown on a chip before truncation — short enough that
    /// several chips fit on the strip above the composer.
    public static let previewLimit = 24

    public var count: Int { messages.count }
    public var isEmpty: Bool { messages.isEmpty }
    public var isEditing: Bool { editing != nil }

    /// The "N queued" indicator, or `nil` when nothing is queued.
    public var indicator: String? {
        isEmpty ? nil : "\(count) queued"
    }

    public var chips: [QueuedChip] {
        messages.enumerated().map { index, text in
            QueuedChip(id: index, text: text, preview: Self.preview(text))
        }
    }

    /// A short single-line chip label: internal whitespace (including newlines)
    /// collapses to single spaces and an over-long preview is truncated with a
    /// trailing "...", so a long or multi-line queued prompt stays compact.
    public static func preview(_ text: String, max: Int = previewLimit) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > max else { return collapsed }
        return String(collapsed.prefix(Swift.max(0, max - 3))) + "..."
    }

    /// Translate a *visible* chip position into the full-queue index `EditQueued`
    /// expects. While an item is checked out it is absent from `messages`, but
    /// the reducer reinserts it at its original slot *before* indexing — so a
    /// click at or past that slot must skip over it. `RemoveQueued` needs no such
    /// translation: it removes straight from the current outbox.
    public func fullIndex(forVisible visible: Int) -> Int {
        if let editing, visible >= editing { return visible + 1 }
        return visible
    }

    /// Up/Down/Escape recall arithmetic for the composer:
    ///
    /// - **Up** on an *empty* composer recalls: with nothing checked out it grabs
    ///   the last queued message; while editing it steps toward the front. A
    ///   non-empty composer keeps Up as caret movement.
    /// - **Down** while editing steps toward the back; past the last item it
    ///   cancels rather than emitting an out-of-range `EditQueued`.
    /// - **Escape** while editing cancels; otherwise it keeps its default.
    public func decision(for key: RecallKey, composerEmpty: Bool) -> RecallDecision {
        switch key {
        case .up:
            guard composerEmpty, !(editing == nil && isEmpty) else { return .proceed }
            if let editing { return .recall(Swift.max(0, editing - 1)) }
            return .recall(count - 1)
        case .down:
            guard let editing else { return .proceed }
            return editing < count ? .recall(editing + 1) : .cancel
        case .escape:
            return isEditing ? .cancel : .proceed
        }
    }
}
