import Foundation

/// The callers of one kind of MCP inventory request, served one at a time in
/// the order they asked.
///
/// The core's `mcp_builtins` and `mcp_client_servers` events carry no
/// correlation id, so an event cannot name the caller it answers. The core does
/// emit exactly one event per request - a read and a write are answered the
/// same way - so the only thing that can pair the two is order, and order only
/// holds while one request is out at a time. The core runs each request on its
/// own task, and a write does more work than a read, so two requests in flight
/// together can be answered in the other order. This type therefore holds a
/// caller's request back until the request before it has been answered.
///
/// The result is exact pairing: every caller receives the answer to its own
/// request, so a write's caller reads the state its own write produced. Serving
/// them all from the first event to arrive instead gives each caller a state
/// that predates its own request, and drops the answers nobody is left to take
/// (adele-mac#34).
///
/// The cost is that a read waits behind a write. Both are local file work, and
/// the panel already awaits each of them.
///
/// An event that arrives with no request out is ignored. It leaves the queue as
/// it is, so the caller whose turn is next still sends, and still waits for its
/// own answer.
///
/// Main-actor only, like the rest of the core's reply bookkeeping: requests are
/// issued on the main actor and events are delivered there.
final class McpInventoryWaiters<Value: Sendable> {
    /// The caller whose request is out, waiting for the event that answers it.
    private var answering: CheckedContinuation<Value, Never>?

    /// The callers whose turn has not come. Each is resumed when it takes over
    /// the slot, and sends its own request then.
    private var turns: [CheckedContinuation<Void, Never>] = []

    /// True from the moment a request is sent until its answer is delivered.
    /// Held across the handover, so a waiting caller cannot be overtaken.
    private var busy = false

    /// How many callers are in the queue: the one waiting for an answer, plus
    /// the ones waiting for a turn.
    @MainActor
    var count: Int { (answering == nil ? 0 : 1) + turns.count }

    /// Join the queue, send the request when the slot is free, and await the
    /// event that answers it.
    ///
    /// The request goes out after the caller takes the slot, so no event can
    /// arrive before there is a caller for it, and no second request is out
    /// while this one is unanswered.
    @MainActor
    func request(_ send: () -> Void) async -> Value {
        if busy {
            await withCheckedContinuation { (turn: CheckedContinuation<Void, Never>) in
                turns.append(turn)
            }
        }
        busy = true
        return await withCheckedContinuation { continuation in
            answering = continuation
            send()
        }
    }

    /// Answer the caller whose request is out with `value`, and pass the slot to
    /// the caller next in line. Does nothing when no request is out.
    @MainActor
    func deliver(_ value: Value) {
        guard let continuation = answering else { return }
        answering = nil
        if turns.isEmpty {
            busy = false
        } else {
            // The slot passes straight to the head of the queue, which sends its
            // own request when it resumes.
            turns.removeFirst().resume()
        }
        continuation.resume(returning: value)
    }
}
