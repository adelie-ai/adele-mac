import Foundation
import Testing

@testable import AdeleCore

/// Spec for the queue that matches an MCP inventory event to the caller that
/// asked for it (adele-mac#34).
///
/// The events carry no correlation id, so the only thing that can match a reply
/// to a request is order. These cases pin that rule without a core: the same
/// queue serves the client-run inventory and the built-in one.
@Suite struct McpInventoryWaitersTests {
    /// Two requests in flight get one event each, oldest first - so a write that
    /// starts while a read is out is answered by its own event, not the read's.
    @MainActor @Test func overlappingRequestsEachReceiveTheirOwnReply() async {
        let waiters = McpInventoryWaiters<[McpClientServer]>()
        let notes = McpClientServer(
            name: "notes", transport: "stdio", status: "enabled", toolCount: 0
        )

        let first = Task { await waiters.request {} }
        while waiters.count < 1 { await Task.yield() }
        let second = Task { await waiters.request {} }
        while waiters.count < 2 { await Task.yield() }

        waiters.deliver([notes])
        waiters.deliver([])

        #expect(await first.value == [notes], "the older caller gets the older event")
        #expect(await second.value == [], "the newer caller gets its own event")
    }

    /// An event that arrives with nobody waiting is ignored, and the caller that
    /// asks next still gets the event its own request produces.
    @MainActor @Test func anEventWithNoWaiterIsIgnored() async {
        let waiters = McpInventoryWaiters<[McpClientServer]>()
        let notes = McpClientServer(
            name: "notes", transport: "stdio", status: "enabled", toolCount: 0
        )

        waiters.deliver([notes])  // unsolicited: the core emits these too

        let later = Task { await waiters.request {} }
        while waiters.count < 1 { await Task.yield() }
        waiters.deliver([])

        #expect(await later.value == [], "the dropped event must not be held back for this caller")
    }

    /// The built-in inventory is queued by the same rule: it arrives on its own
    /// event with no correlation id, and a toggle's caller must be answered by
    /// the toggle's own event.
    @MainActor @Test func builtinInventoryFollowsTheSameOrder() async {
        let waiters = McpInventoryWaiters<[McpBuiltinServer]>()
        let on = McpBuiltinServer(name: "web", namespace: "web", toolCount: 3)
        let off = McpBuiltinServer(
            name: "web", namespace: "web", toolCount: 3, disabledByConfig: true
        )

        let read = Task { await waiters.request {} }
        while waiters.count < 1 { await Task.yield() }
        let toggle = Task { await waiters.request {} }
        while waiters.count < 2 { await Task.yield() }

        waiters.deliver([on])
        waiters.deliver([off])

        #expect(await read.value == [on])
        #expect(await toggle.value == [off], "the toggle's caller sees the state it wrote")
    }

    /// The request goes out only after its caller joins the queue, so an event
    /// can never arrive before there is a waiter for it.
    @MainActor @Test func theRequestIsSentAfterTheCallerJoinsTheQueue() async {
        let waiters = McpInventoryWaiters<[McpClientServer]>()
        let counted = CountingSend(waiters: waiters)

        let caller = Task { await waiters.request { counted.record() } }
        while waiters.count < 1 { await Task.yield() }

        #expect(counted.waitersWhenSent == 1, "the caller is queued before the core is asked")
        waiters.deliver([])
        _ = await caller.value
    }

    /// Records how many callers were queued at the moment the request went out.
    @MainActor private final class CountingSend {
        private let waiters: McpInventoryWaiters<[McpClientServer]>
        private(set) var waitersWhenSent = 0

        init(waiters: McpInventoryWaiters<[McpClientServer]>) {
            self.waiters = waiters
        }

        func record() { waitersWhenSent = waiters.count }
    }
}
