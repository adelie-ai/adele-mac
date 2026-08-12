import Foundation

/// Half-typed composer text, keyed by conversation id (#7).
///
/// A single global draft carried the wrong text across a conversation switch (and
/// lost it on switch-back). Keying by conversation makes the composer restore
/// whatever that conversation was left mid-sentence with, and makes the
/// clear-on-send drop only the conversation actually sent into — a background
/// queue flush into another conversation can never wipe a fresh draft.
///
/// A `nil` conversation id (nothing open) gets its own slot rather than being
/// dropped, so text typed before a conversation exists is not silently lost.
/// Assigning an empty string removes the entry, so `isEmpty` means "no drafts".
public struct DraftStore: Equatable, Sendable {
    /// The `nil`-conversation slot. Conversation ids are non-empty, so this can
    /// never collide with a real one.
    private static let unattached = ""

    private var drafts: [String: String] = [:]

    public init() {}

    public subscript(conversationID: String?) -> String {
        get { drafts[conversationID ?? Self.unattached] ?? "" }
        set {
            let key = conversationID ?? Self.unattached
            if newValue.isEmpty {
                drafts.removeValue(forKey: key)
            } else {
                drafts[key] = newValue
            }
        }
    }

    /// Drop the draft for one conversation (the clear-on-send path).
    public mutating func clear(_ conversationID: String?) {
        self[conversationID] = ""
    }

    /// Forget a conversation entirely (it was deleted).
    public mutating func forget(_ conversationID: String) {
        drafts.removeValue(forKey: conversationID)
    }

    public var isEmpty: Bool { drafts.isEmpty }
}

/// The text `draft` sends, or `nil` when it holds no message.
///
/// One rule, one place, because two callers ask the same question and must get
/// the same answer: the send control asks whether to offer a send, and the send
/// path asks whether one happened. The second answer matters beyond the message:
/// a dictation session resets on send, which drops the words the recognizer
/// still holds, so a reset after a refused send destroys a sentence nothing
/// received. Whitespace alone is no message.
public func promptToSend(draft: String) -> String? {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
}
