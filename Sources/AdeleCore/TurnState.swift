import Foundation

/// What this client knows about the turn running in the open conversation.
///
/// Both facts come from the shared reducer, which is the only thing that can
/// know them: whether the turn can be cancelled, and whether a turn that failed
/// left its prompt to be offered back. This type holds the reported answer and
/// the one rule the client applies to it, so the decision is testable without a
/// live core behind it.
public struct TurnState: Sendable, Equatable {
    /// The background-task id the daemon registered for the running turn, or
    /// `nil` when there is nothing to cancel.
    public private(set) var cancelableTaskID: String?

    public init() {}

    /// Whether a Cancel control should be offered.
    ///
    /// Exactly "there is a handle". A control shown without one would send a
    /// command naming no task, which the daemon cannot act on and the user would
    /// read as a cancel that did nothing.
    public var canCancel: Bool { cancelableTaskID != nil }

    /// Adopt the handle the core reported.
    public mutating func apply(activeTaskID: String?) {
        cancelableTaskID = activeTaskID
    }

    /// The composer text to set when the core offers a failed prompt back, or
    /// `nil` to leave the composer alone.
    ///
    /// The offer is applied only to an empty composer. A user who typed while
    /// waiting is mid-thought, and replacing that to restore an older prompt
    /// would lose work in the act of recovering work. Whitespace alone counts as
    /// empty, because it holds nothing the user would miss.
    public static func composerAfterRetryOffer(_ offered: String, composer: String) -> String? {
        composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? offered : nil
    }
}
