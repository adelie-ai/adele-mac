import Foundation

/// The callers awaiting one kind of MCP inventory event, in the order they
/// asked for it.
///
/// The core's `mcp_builtins` and `mcp_client_servers` events carry no
/// correlation id, so an event cannot name the caller it answers. The core does
/// emit exactly one event per request, so arrival order is request order: each
/// event resolves exactly one caller, the oldest first. An event that arrives
/// with nobody waiting - the core also emits an inventory of its own accord -
/// is ignored, and leaves any later waiter in place.
///
/// Resolving every waiter with one event instead would give each caller the
/// first answer to arrive, which for a write is the state before its own write
/// (adele-mac#34).
///
/// Main-actor only, like the rest of the core's reply bookkeeping: requests are
/// issued on the main actor and events are delivered there.
final class McpInventoryWaiters<Value: Sendable> {
    private var waiting: [CheckedContinuation<Value, Never>] = []

    /// How many callers await an answer right now.
    @MainActor
    var count: Int { waiting.count }

    /// Join the queue, send the request, and await the event that answers it.
    ///
    /// The request goes out after the caller joins, so no event can arrive
    /// before its waiter is in place.
    @MainActor
    func request(_ send: () -> Void) async -> Value {
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
            send()
        }
    }

    /// Answer the oldest waiting caller with `value`. Does nothing when no
    /// caller waits.
    @MainActor
    func deliver(_ value: Value) {
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().resume(returning: value)
    }
}
