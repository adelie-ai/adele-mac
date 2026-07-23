import CAdeleCore
import Foundation

// Message-queuing intents (#1). While a reply streams, a submit is QUEUED by the
// shared reducer rather than refused; these are the three inputs that let the
// user curate that queue before it flushes as one combined turn. Like every
// other intent they are fire-and-forget — the outcome arrives as `composer_text`
// / `queued_messages` view-events.
extension AdeleCore {
    /// Check out queued message `index` into the composer to edit it (a chip's
    /// edit affordance, or up-arrow recall). The text arrives as a
    /// `composer_text` event; re-submitting reinserts it in place. `index` is a
    /// FULL-queue index — translate a chip's rendered position with
    /// `QueuedMessagesState.fullIndex(forVisible:)`. Out of range is ignored.
    public func editQueued(_ index: Int) {
        guard let handle, index >= 0 else { return }
        adele_core_edit_queued(handle, UInt(index))
    }

    /// Drop queued message `index` without sending it (a chip's x). The index is
    /// the rendered position — `RemoveQueued` removes straight from the outbox,
    /// so no translation is needed. Out of range is ignored.
    public func removeQueued(_ index: Int) {
        guard let handle, index >= 0 else { return }
        adele_core_remove_queued(handle, UInt(index))
    }

    /// Abandon an in-progress queued-message edit: the checked-out message
    /// returns to the queue unchanged and the composer clears. A no-op when not
    /// editing.
    public func cancelQueuedEdit() {
        guard let handle else { return }
        adele_core_cancel_queued_edit(handle)
    }
}
