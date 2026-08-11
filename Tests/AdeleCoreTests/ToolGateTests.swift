import Foundation
import Testing

@testable import AdeleCore

/// Spec for the per-conversation tool-provenance-gate override
/// (desktop-assistant#1007): reading the stored state off a loaded conversation,
/// and writing a new one.
@Suite struct ToolGateTests {
    // MARK: Reading the stored state

    private func detail(_ json: String) throws -> ConversationDetail {
        try JSONDecoder().decode(ConversationDetail.self, from: Data(json.utf8))
    }

    /// A conversation whose gate was turned off says so, so the control shows
    /// the state the daemon holds rather than a fresh default.
    @Test func aDisabledGateIsReadOffTheConversation() throws {
        let detail = try detail(
            #"{"id":"c1","title":"t","messages":[],"tool_gate_disabled":true}"#)
        #expect(detail.toolGateDisabled)
    }

    /// A conversation with the gate enforced reads as enforced.
    @Test func anEnforcedGateIsReadOffTheConversation() throws {
        let detail = try detail(
            #"{"id":"c1","title":"t","messages":[],"tool_gate_disabled":false}"#)
        #expect(detail.toolGateDisabled == false)
    }

    /// A core too old to report the field must not fail the whole conversation
    /// load. The gate reads as enforced, which is the daemon's own default and
    /// the safe reading of an unknown state.
    @Test func aCoreThatDoesNotReportTheGateLoadsAnyway() throws {
        let detail = try detail(#"{"id":"c1","title":"t","messages":[]}"#)
        #expect(detail.toolGateDisabled == false)
    }

    // MARK: Writing a new state

    /// `AdeleCommand` builders return the wire JSON as a string, so a case
    /// parses that back rather than re-encoding the builder.
    private func wire(_ json: String) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    /// Turning the gate off sends the command the daemon defines, under the
    /// externally-tagged snake_case name it expects.
    @Test func disablingTheGateBuildsTheDaemonsCommand() throws {
        let json = try wire(
            AdeleCommand.setConversationToolGate(conversationID: "c1", disabled: true))

        let payload = try #require(json["set_conversation_tool_gate"] as? [String: Any])
        #expect(payload["conversation_id"] as? String == "c1")
        #expect(payload["disabled"] as? Bool == true)
    }

    /// Turning it back on sends `false` rather than omitting the field, so the
    /// daemon stores an explicit choice instead of reading a missing key.
    @Test func enforcingTheGateSendsAnExplicitFalse() throws {
        let json = try wire(
            AdeleCommand.setConversationToolGate(conversationID: "c1", disabled: false))
        let payload = try #require(json["set_conversation_tool_gate"] as? [String: Any])
        #expect(payload["disabled"] as? Bool == false)
    }

    // MARK: What the daemon echoes back

    /// The daemon answers with the value it stored. The client adopts that
    /// rather than its own optimistic guess, so a write the daemon changed or
    /// refused cannot leave the control claiming a state the daemon does not
    /// hold.
    @Test func theStoredValueIsReadFromTheReply() throws {
        let data = Data(#"{"result":{"conversation_tool_gate":{"disabled":true}}}"#.utf8)
        let envelope = try JSONDecoder().decode(
            CommandResultEnvelope<ConversationToolGateResultPayload>.self, from: data)
        #expect(envelope.result?.conversationToolGate.disabled == true)
    }

    /// A reply that is not this command's result yields nothing, so a caller
    /// cannot mistake an unrelated payload for a confirmed write.
    @Test func anUnrelatedReplyYieldsNoStoredValue() throws {
        let data = Data(#"{"result":{"ack":{}}}"#.utf8)
        let envelope = try? JSONDecoder().decode(
            CommandResultEnvelope<ConversationToolGateResultPayload>.self, from: data)
        #expect(envelope?.result == nil)
    }
}
