import Foundation
import Testing

@testable import AdeleCore

/// Spec for the queue that matches an MCP inventory event to the caller that
/// asked for it (adele-mac#34).
///
/// The events carry no correlation id, so the only thing that can match a reply
/// to a request is order, and only one request may be out at a time for order
/// to mean anything. These cases pin both rules without a core: the same queue
/// serves the client-run inventory and the built-in one.
@Suite struct McpInventoryWaitersTests {
    /// Counts the requests that reached the core, so a test can wait for a
    /// request to go out rather than guess at the scheduling.
    @MainActor private final class SendLog {
        private(set) var sent = 0

        func record() { sent += 1 }
    }

    private func clientServer(_ name: String) -> McpClientServer {
        McpClientServer(name: name, transport: "stdio", status: "enabled", toolCount: 0)
    }

    /// Two callers in the queue get one event each, oldest first - so a write
    /// that starts while a read is out is answered by its own event.
    @MainActor @Test func overlappingRequestsEachReceiveTheirOwnReply() async {
        let waiters = McpInventoryWaiters<[McpClientServer]>()
        let log = SendLog()
        let notes = clientServer("notes")

        let first = Task { await waiters.request { log.record() } }
        while waiters.count < 1 { await Task.yield() }
        let second = Task { await waiters.request { log.record() } }
        while waiters.count < 2 { await Task.yield() }

        waiters.deliver([notes])
        while log.sent < 2 { await Task.yield() }
        waiters.deliver([])

        #expect(await first.value == [notes], "the older caller gets the answer to its request")
        #expect(await second.value == [], "the newer caller gets the answer to its own")
    }

    /// One request is out at a time. The core answers each request on its own
    /// task, so a second request sent while the first is unanswered could be
    /// answered first, and the two callers would swap answers.
    @MainActor @Test func oneRequestIsOutAtATime() async {
        let waiters = McpInventoryWaiters<[McpClientServer]>()
        let log = SendLog()

        let first = Task { await waiters.request { log.record() } }
        while waiters.count < 1 { await Task.yield() }
        let second = Task { await waiters.request { log.record() } }
        while waiters.count < 2 { await Task.yield() }

        #expect(log.sent == 1, "the second caller waits its turn rather than asking as well")

        waiters.deliver([])
        while log.sent < 2 { await Task.yield() }
        #expect(log.sent == 2, "the answer to the first request releases the second")

        waiters.deliver([])
        _ = await first.value
        _ = await second.value
    }

    /// An event that arrives with no request out is ignored, and the caller that
    /// asks next still gets the event its own request produces.
    @MainActor @Test func anEventWithNoWaiterIsIgnored() async {
        let waiters = McpInventoryWaiters<[McpClientServer]>()
        let log = SendLog()
        let notes = clientServer("notes")

        waiters.deliver([notes])

        let later = Task { await waiters.request { log.record() } }
        while log.sent < 1 { await Task.yield() }
        waiters.deliver([])

        #expect(await later.value == [], "the dropped event must not be held back for this caller")
    }

    /// The built-in inventory is queued by the same rule: it arrives on its own
    /// event with no correlation id, and a toggle's caller must be answered by
    /// the toggle's own event.
    @MainActor @Test func builtinInventoryFollowsTheSameOrder() async {
        let waiters = McpInventoryWaiters<[McpBuiltinServer]>()
        let log = SendLog()
        let on = McpBuiltinServer(name: "web", namespace: "web", toolCount: 3)
        let off = McpBuiltinServer(
            name: "web", namespace: "web", toolCount: 3, disabledByConfig: true
        )

        let read = Task { await waiters.request { log.record() } }
        while waiters.count < 1 { await Task.yield() }
        let toggle = Task { await waiters.request { log.record() } }
        while waiters.count < 2 { await Task.yield() }

        waiters.deliver([on])
        while log.sent < 2 { await Task.yield() }
        waiters.deliver([off])

        #expect(await read.value == [on])
        #expect(await toggle.value == [off], "the toggle's caller sees the state it wrote")
    }

    /// The request goes out only after its caller takes the slot, so an event
    /// can never arrive before there is a caller for it.
    @MainActor @Test func theRequestIsSentAfterTheCallerTakesTheSlot() async {
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
