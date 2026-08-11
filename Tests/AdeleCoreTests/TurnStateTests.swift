import Foundation
import Testing

@testable import AdeleCore

/// Spec for decoding the turn-state view events the core reports: the cancel
/// handle for the open turn (`active_turn`) and the one-shot retry offer for a
/// turn that failed (`retry_prompt`).
///
/// The reducer decides both; this client only reads them. So the assertions here
/// are about the wire form, and the behaviour that depends on it lives in
/// ``TurnStateModelTests``.
@Suite struct TurnStateEventTests {
    private func decode(_ json: String) throws -> ViewEvent {
        try JSONDecoder().decode(ViewEvent.self, from: Data(json.utf8))
    }

    /// A turn in flight reports the id Cancel acts on.
    @Test func anActiveTurnCarriesItsCancelHandle() throws {
        guard case .activeTurn(let taskID) = try decode(
            #"{"type":"active_turn","task_id":"task-42"}"#)
        else { return #expect(Bool(false), "expected an activeTurn event") }
        #expect(taskID == "task-42")
    }

    /// Nothing to cancel arrives as an explicit null.
    @Test func aNullHandleMeansNothingToCancel() throws {
        guard case .activeTurn(let taskID) = try decode(#"{"type":"active_turn","task_id":null}"#)
        else { return #expect(Bool(false), "expected an activeTurn event") }
        #expect(taskID == nil)
    }

    /// A core that omits the field rather than sending null must not throw. The
    /// current core always sends it, so this is about surviving a change to that
    /// rather than about today's wire form.
    @Test func anAbsentHandleDecodesAsNothingToCancel() throws {
        guard case .activeTurn(let taskID) = try decode(#"{"type":"active_turn"}"#)
        else { return #expect(Bool(false), "expected an activeTurn event") }
        #expect(taskID == nil)
    }

    /// The retry offer carries the prompt that failed.
    @Test func aRetryOfferCarriesTheFailedPrompt() throws {
        guard case .retryPrompt(let text) = try decode(
            #"{"type":"retry_prompt","text":"what is the time"}"#)
        else { return #expect(Bool(false), "expected a retryPrompt event") }
        #expect(text == "what is the time")
    }
}

/// Spec for what this client does with the two turn-state events.
///
/// Kept as pure state rather than driven through `AppModel`, which needs a live
/// core: ``TurnState`` is the whole decision, so testing it tests the rule.
@Suite struct TurnStateModelTests {
    // MARK: The cancel handle

    /// Nothing is cancelable before a turn starts, so no control is offered.
    @Test func noTurnMeansNoCancelControl() {
        #expect(TurnState().cancelableTaskID == nil)
        #expect(TurnState().canCancel == false)
    }

    /// A turn in flight offers its handle.
    @Test func aTurnInFlightCanBeCancelled() {
        var state = TurnState()
        state.apply(activeTaskID: "task-42")
        #expect(state.cancelableTaskID == "task-42")
        #expect(state.canCancel)
    }

    /// A finished or abandoned turn withdraws it, so the control disappears
    /// rather than lingering with a dead id behind it.
    @Test func aFinishedTurnCannotBeCancelled() {
        var state = TurnState()
        state.apply(activeTaskID: "task-42")
        state.apply(activeTaskID: nil)
        #expect(state.cancelableTaskID == nil)
        #expect(state.canCancel == false)
    }

    // MARK: The retry offer

    /// A failed turn's prompt goes back into an empty composer, so resending is
    /// one click.
    @Test func aFailedPromptReturnsToAnEmptyComposer() {
        #expect(TurnState.composerAfterRetryOffer("hello", composer: "") == "hello")
    }

    /// Text typed while waiting is never overwritten. The user was mid-thought;
    /// silently replacing it would lose work to recover work.
    @Test func aFailedPromptNeverOverwritesTypedText() {
        #expect(TurnState.composerAfterRetryOffer("hello", composer: "half a thought") == nil)
    }

    /// A composer holding only whitespace counts as empty - it holds nothing the
    /// user would miss.
    @Test func aWhitespaceOnlyComposerCountsAsEmpty() {
        #expect(TurnState.composerAfterRetryOffer("hello", composer: "   \n ") == "hello")
    }
}
