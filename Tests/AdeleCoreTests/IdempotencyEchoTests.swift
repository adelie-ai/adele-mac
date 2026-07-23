import Foundation
import Testing
@testable import AdeleCore

// Spec (#8): a send must draw EXACTLY ONE user bubble, for both a direct send
// and a queued flush.
//
// Where the work happens: entirely below Swift. The FFI engine mints a fresh v4
// idempotency key per `SubmitPrompt` (`client-ui-common/ffi/src/engine.rs`,
// `submit_prompt_message`), emits the single optimistic `add_user_message` when
// the reducer's `SendPrompt` effect runs (`run_rpc_effect`), and forwards the
// key on the `SendMessage` wire frame. The reducer then swallows the daemon's
// echoed `UserMessageAdded` when it matches an optimistic bubble by exact key
// (`client-ui-common/src/reducer.rs`, `UiMessage::UserMessageAdded`). A queue
// flush joins the whole outbox into ONE combined prompt that adopts the first
// queued message's key, so it too produces one `SendPrompt` → one bubble.
//
// So — unlike GTK (#137) and TUI (#129), which host the reducer directly and had
// to mint/thread the key themselves — adele-mac has nothing to thread: it drives
// the same shared engine over the C ABI and simply renders one bubble per
// `add_user_message` event (`AppModel.apply` → `appendUser`). It must NOT append
// its own bubble in `send()`, which is what this test pins.
//
// The assertion is therefore an end-to-end one and needs a live daemon. It is
// skipped unless `ADELE_WS_URL` (plus `ADELE_WS_PASS`, or `ADELE_WS_JWT`) is set:
//
//   ADELE_WS_URL=ws://host:11339/ws ADELE_WS_USER=adele ADELE_WS_PASS=… \
//     ./scripts/test.sh --filter IdempotencyEchoTests

/// Drives a real `AdeleCore` against a live daemon and records the view-events.
@MainActor
private final class LiveSession {
    let core = AdeleCore()
    private(set) var userBubbles: [String] = []
    private(set) var completes = 0
    private(set) var lastDetail: ConversationDetail?
    /// Set by the reconnect test once it has dropped and re-opened the socket.
    var didReconnect = false
    private var onEvent: ((ViewEvent) -> Void)?

    func start(url: String, token: String, observe: @escaping (ViewEvent) -> Void) {
        onEvent = observe
        core.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .addUserMessage(let content): self.userBubbles.append(content)
            case .complete: self.completes += 1
            case .loadConversation(let detail): self.lastDetail = detail
            default: break
            }
            self.onEvent?(event)
        }
        core.setWSJWT(token)
        core.connect(transport: "ws", address: url)
    }
}

@Suite struct IdempotencyEchoTests {
    private static let env = ProcessInfo.processInfo.environment
    private static var wsURL: String? { env["ADELE_WS_URL"] }
    static var live: Bool { wsURL != nil && (env["ADELE_WS_PASS"] != nil || env["ADELE_WS_JWT"] != nil) }

    private static func token() async throws -> String {
        if let explicit = env["ADELE_WS_JWT"], !explicit.isEmpty { return explicit }
        return try await WSLogin.token(
            wsURL: wsURL!,
            username: env["ADELE_WS_USER"] ?? "adele",
            password: env["ADELE_WS_PASS"] ?? ""
        )
    }

    /// A direct send and a queued flush must each draw exactly one user bubble:
    /// two turns ⇒ two `add_user_message` events, the second being the queued
    /// pair joined into one combined turn.
    @Test(.enabled(if: IdempotencyEchoTests.live), .timeLimit(.minutes(3)))
    func sendAndQueuedFlushEachDrawOneUserBubble() async throws {
        let url = try #require(Self.wsURL)
        let token = try await Self.token()

        let session = await LiveSession()
        var sentFirst = false
        var queuedYet = false
        await MainActor.run {
            session.start(url: url, token: token) { event in
                switch event {
                case .connected:
                    session.core.newConversation()
                case .loadConversation(let detail) where detail.messages.isEmpty:
                    // The fresh conversation can be re-emitted (list refresh) before
                    // the daemon has persisted the user row — send into it once.
                    guard !sentFirst else { break }
                    sentFirst = true
                    session.core.sendPrompt("Say the single word: one.")
                case .chunk:
                    // The reply is streaming — these two must QUEUE, not send,
                    // and flush as ONE combined turn when it completes.
                    if !queuedYet {
                        queuedYet = true
                        session.core.sendPrompt("Say the single word: two.")
                        session.core.sendPrompt("Say the single word: three.")
                    }
                default:
                    break
                }
            }
        }

        // Wait for both turns to complete (the direct send, then the flush).
        let deadline = Date().addingTimeInterval(150)
        while await MainActor.run(body: { session.completes < 2 }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }

        let bubbles = await MainActor.run { session.userBubbles }
        #expect(bubbles.count == 2, "expected one bubble per turn, got: \(bubbles)")
        #expect(bubbles.first == "Say the single word: one.")
        #expect(
            bubbles.last == "Say the single word: two.\n\nSay the single word: three.",
            "the flush must send the queue as ONE combined turn"
        )
    }

    /// Reconnecting mid-turn must neither duplicate nor lose the turn: the
    /// re-attach replays the live turn, and the echoed `UserMessageAdded` dedupes
    /// against the optimistic bubble by idempotency key (#570 / daemon#593).
    @Test(.enabled(if: IdempotencyEchoTests.live), .timeLimit(.minutes(3)))
    func reconnectMidTurnNeitherDuplicatesNorLosesTheTurn() async throws {
        let url = try #require(Self.wsURL)
        let token = try await Self.token()
        let prompt = "Count slowly from one to twenty, one number per line."

        let session = await LiveSession()
        var sentFirst = false
        await MainActor.run {
            session.start(url: url, token: token) { event in
                switch event {
                case .connected where !sentFirst:
                    session.core.newConversation()
                case .loadConversation(let detail) where detail.messages.isEmpty && !sentFirst:
                    sentFirst = true
                    session.core.sendPrompt(prompt)
                case .chunk:
                    // Drop and re-open the socket while the reply streams.
                    if !session.didReconnect {
                        session.didReconnect = true
                        session.core.setWSJWT(token)
                        session.core.connect(transport: "ws", address: url)
                    }
                default:
                    break
                }
            }
        }

        let deadline = Date().addingTimeInterval(150)
        while await MainActor.run(body: { session.completes < 1 }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }

        let (bubbles, completes, reconnected) = await MainActor.run {
            (session.userBubbles, session.completes, session.didReconnect)
        }
        #expect(reconnected, "the test never reconnected — no chunk arrived")
        #expect(bubbles == [prompt], "the reconnect must not re-draw the user bubble: \(bubbles)")
        #expect(completes >= 1, "the turn was lost across the reconnect")

        // And the persisted transcript holds exactly one user row for the turn.
        await MainActor.run { session.core.selectConversation(session.lastDetail?.id ?? "") }
        try await Task.sleep(for: .seconds(2))
        let userRows = await MainActor.run {
            session.lastDetail?.messages.filter { $0.role == "user" } ?? []
        }
        #expect(userRows.map(\.content) == [prompt], "persisted transcript: \(userRows)")
    }
}
