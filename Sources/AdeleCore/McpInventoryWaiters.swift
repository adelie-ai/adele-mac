import Foundation

/// The callers awaiting one kind of MCP inventory event, in the order they
/// asked for it.
///
/// The core's `mcp_builtins` and `mcp_client_servers` events carry no
/// correlation id, so an event cannot name the caller it answers. The core does
/// emit exactly one event per request - a read and a write are answered the
/// same way - so order is what pairs the two: each event answers exactly one
/// caller, the oldest first. An event that arrives with nobody waiting is
/// ignored, and leaves any later caller waiting for its own.
///
/// Answering every caller with one event instead gives them all the first
/// answer to arrive, which for a write is the state before that write, and
/// drops the write's own event (adele-mac#34).
///
/// What this does not promise: the core runs each request on its own task, so
/// two requests in flight together can be answered in the other order, and each
/// caller then takes up the other's answer. Every request is still answered
/// exactly once. Pairing an answer to its own request needs a correlation id on
/// the event, which is adele-mac#39.
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
