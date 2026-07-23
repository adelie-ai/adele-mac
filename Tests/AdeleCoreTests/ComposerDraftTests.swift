import Testing
@testable import AdeleCore

/// Spec (#7): the composer draft is keyed by conversation id, so switching
/// conversations restores that conversation's half-typed message instead of
/// carrying one draft across all of them, and clearing on send drops only the
/// active conversation's draft.
@Suite struct ComposerDraftTests {
    @Test func unknownConversationStartsEmpty() {
        let store = DraftStore()
        #expect(store["c1"] == "")
        #expect(store.isEmpty)
    }

    @Test func draftsAreKeyedPerConversation() {
        var store = DraftStore()
        store["c1"] = "half typed for one"
        store["c2"] = "different thought"
        #expect(store["c1"] == "half typed for one")
        #expect(store["c2"] == "different thought")
    }

    @Test func switchingAwayAndBackRestoresTheDraft() {
        var store = DraftStore()
        store["c1"] = "keep me"
        // Switch to c2, type there, switch back — c1's draft must survive.
        store["c2"] = "other"
        #expect(store["c1"] == "keep me")
    }

    @Test func clearOnlyDropsTheActiveConversation() {
        var store = DraftStore()
        store["c1"] = "sent now"
        store["c2"] = "still typing"
        store.clear("c1")
        #expect(store["c1"] == "")
        #expect(store["c2"] == "still typing")
    }

    @Test func assigningEmptyDropsTheEntry() {
        var store = DraftStore()
        store["c1"] = "x"
        store["c1"] = ""
        #expect(store.isEmpty)
    }

    @Test func forgetDropsADeletedConversationsDraft() {
        var store = DraftStore()
        store["c1"] = "gone with it"
        store["c2"] = "stays"
        store.forget("c1")
        #expect(store["c1"] == "")
        #expect(store["c2"] == "stays")
    }

    @Test func noOpenConversationHasItsOwnSlot() {
        var store = DraftStore()
        store[nil] = "typed with nothing open"
        #expect(store[nil] == "typed with nothing open")
        #expect(store["c1"] == "")
    }
}
