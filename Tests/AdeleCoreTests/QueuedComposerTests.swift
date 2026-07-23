import Foundation
import Testing
@testable import AdeleCore

/// Spec (#1): the new message-queuing view-events decode into typed cases so the
/// composer can render "N queued" chips and reload a recalled message.
@Suite struct ComposerViewEventDecodingTests {
    private func decode(_ json: String) throws -> ViewEvent {
        try JSONDecoder().decode(ViewEvent.self, from: Data(json.utf8))
    }

    @Test func composerText() throws {
        guard case .composerText(let text) = try decode(#"{"type":"composer_text","text":"recalled"}"#)
        else { Issue.record("expected .composerText"); return }
        #expect(text == "recalled")
    }

    @Test func composerTextClear() throws {
        guard case .composerText(let text) = try decode(#"{"type":"composer_text","text":""}"#)
        else { Issue.record("expected .composerText"); return }
        #expect(text.isEmpty)
    }

    @Test func queuedMessages() throws {
        let json = #"{"type":"queued_messages","messages":["a","b"],"editing":null}"#
        guard case .queuedMessages(let messages, let editing) = try decode(json)
        else { Issue.record("expected .queuedMessages"); return }
        #expect(messages == ["a", "b"])
        #expect(editing == nil)
    }

    @Test func queuedMessagesWhileEditing() throws {
        let json = #"{"type":"queued_messages","messages":["a"],"editing":1}"#
        guard case .queuedMessages(let messages, let editing) = try decode(json)
        else { Issue.record("expected .queuedMessages"); return }
        #expect(messages == ["a"])
        #expect(editing == 1)
    }
}

/// Spec (#1): the pure view-state behind the queued-chips strip — the "N queued"
/// indicator, chip previews, the visible→full index translation `EditQueued`
/// needs, and the Up/Down/Escape recall arithmetic. Mirrors the GTK client's
/// `compose_status` / `chip_preview` / `chip_edit_index` / `recall_decision`.
@Suite struct QueuedMessagesStateTests {
    @Test func emptyQueueHasNoIndicator() {
        let state = QueuedMessagesState()
        #expect(state.isEmpty)
        #expect(state.count == 0)
        #expect(state.indicator == nil)
        #expect(!state.isEditing)
    }

    @Test func indicatorCountsQueuedMessages() {
        #expect(QueuedMessagesState(messages: ["a"]).indicator == "1 queued")
        #expect(QueuedMessagesState(messages: ["a", "b", "c"]).indicator == "3 queued")
    }

    @Test func chipsExposeVisibleIndexAndPreview() {
        let state = QueuedMessagesState(messages: ["first", "second"])
        #expect(state.chips.map(\.id) == [0, 1])
        #expect(state.chips.map(\.preview) == ["first", "second"])
        #expect(state.chips.map(\.text) == ["first", "second"])
    }

    @Test func previewCollapsesWhitespaceAndTruncates() {
        #expect(QueuedMessagesState.preview("one\n  two   three", max: 24) == "one two three")
        let long = String(repeating: "x", count: 40)
        let preview = QueuedMessagesState.preview(long, max: 10)
        #expect(preview.count == 10)
        #expect(preview.hasSuffix("..."))
    }

    @Test func editIndexPassesThroughWhenNothingCheckedOut() {
        let state = QueuedMessagesState(messages: ["a", "b", "c"])
        #expect(state.fullIndex(forVisible: 0) == 0)
        #expect(state.fullIndex(forVisible: 2) == 2)
    }

    @Test func editIndexSkipsTheCheckedOutSlot() {
        // "b" (full index 1) is checked out, so the rendered list is ["a","c"]:
        // a click on visible 1 ("c") must target full index 2, because the
        // reducer reinserts the checked-out item before indexing.
        let state = QueuedMessagesState(messages: ["a", "c"], editing: 1)
        #expect(state.fullIndex(forVisible: 0) == 0)
        #expect(state.fullIndex(forVisible: 1) == 2)
    }

    @Test func upOnAnEmptyComposerRecallsTheLastQueuedMessage() {
        let state = QueuedMessagesState(messages: ["a", "b", "c"])
        #expect(state.decision(for: .up, composerEmpty: true) == .recall(2))
    }

    @Test func upWithTextInTheComposerIsCaretMovement() {
        let state = QueuedMessagesState(messages: ["a"])
        #expect(state.decision(for: .up, composerEmpty: false) == .proceed)
    }

    @Test func upWithNothingQueuedIsCaretMovement() {
        #expect(QueuedMessagesState().decision(for: .up, composerEmpty: true) == .proceed)
    }

    @Test func upWhileEditingStepsTowardTheFront() {
        let state = QueuedMessagesState(messages: ["a", "c"], editing: 1)
        #expect(state.decision(for: .up, composerEmpty: true) == .recall(0))
        let atFront = QueuedMessagesState(messages: ["b"], editing: 0)
        #expect(atFront.decision(for: .up, composerEmpty: true) == .recall(0))
    }

    @Test func downWhileEditingStepsTowardTheBack() {
        let state = QueuedMessagesState(messages: ["a", "c"], editing: 0)
        #expect(state.decision(for: .down, composerEmpty: true) == .recall(1))
    }

    @Test func downPastTheLastQueuedItemCancelsTheEdit() {
        // Editing the last slot: stepping further back leaves the queue, which
        // must cancel rather than emit an out-of-range EditQueued.
        let state = QueuedMessagesState(messages: ["a"], editing: 1)
        #expect(state.decision(for: .down, composerEmpty: true) == .cancel)
    }

    @Test func downWithNoEditIsCaretMovement() {
        let state = QueuedMessagesState(messages: ["a"])
        #expect(state.decision(for: .down, composerEmpty: true) == .proceed)
    }

    @Test func escapeCancelsOnlyWhileEditing() {
        #expect(QueuedMessagesState(messages: ["a"], editing: 0)
            .decision(for: .escape, composerEmpty: false) == .cancel)
        #expect(QueuedMessagesState(messages: ["a"])
            .decision(for: .escape, composerEmpty: false) == .proceed)
    }
}
