import Testing
import Foundation
@testable import AdeleCore

/// Spec: management result payloads and the `command_result` envelope decode
/// from the daemon's exact JSON shapes.
@Suite struct ManagementDecodingTests {
    @Test func connectionViewOk() throws {
        let json = """
        {"id":"default","connector_type":"ollama","display_label":"default (ollama)","availability":{"status":"ok"},"has_credentials":true}
        """
        let view = try JSONDecoder().decode(ConnectionView.self, from: Data(json.utf8))
        #expect(view.id == "default")
        #expect(view.connectorType == "ollama")
        #expect(view.availability.isOk)
        #expect(view.availability.reason == nil)
        #expect(view.hasCredentials)
    }

    @Test func connectionViewUnavailable() throws {
        let json = """
        {"id":"bedrock","connector_type":"bedrock","display_label":"bedrock","availability":{"status":"unavailable","reason":"no credentials"},"has_credentials":false}
        """
        let view = try JSONDecoder().decode(ConnectionView.self, from: Data(json.utf8))
        #expect(view.availability.isOk == false)
        #expect(view.availability.reason == "no credentials")
        #expect(view.hasCredentials == false)
    }

    @Test func purposesViewPartial() throws {
        let json = #"{"interactive":{"connection":"default","model":"llama3.2:1b"}}"#
        let purposes = try JSONDecoder().decode(PurposesView.self, from: Data(json.utf8))
        #expect(purposes.interactive?.connection == "default")
        #expect(purposes.interactive?.model == "llama3.2:1b")
        #expect(purposes.dreaming == nil)
        #expect(purposes.consolidation == nil)
        #expect(purposes.voice == nil)
    }

    /// `voice` is a purpose kind the daemon reports (protocol `PurposeKind`),
    /// so it has to decode — otherwise the Voice row can never know its own
    /// server state and the no-op guard could not recognise a reconcile.
    @Test func purposesViewDecodesVoice() throws {
        let json = #"{"voice":{"connection":"bedrock","model":"zai.glm-5"}}"#
        let purposes = try JSONDecoder().decode(PurposesView.self, from: Data(json.utf8))
        #expect(purposes.voice?.connection == "bedrock")
        #expect(purposes.voice?.model == "zai.glm-5")
    }

    /// The per-purpose context-window override (desktop-assistant#51) must
    /// round-trip: `SetPurpose` is a full replace, so a value this client
    /// cannot read is a value it will silently clear.
    @Test func purposeConfigDecodesMaxContextTokens() throws {
        let json = #"{"connection":"bedrock","model":"zai.glm-5","effort":"high","max_context_tokens":8192}"#
        let config = try JSONDecoder().decode(PurposeConfigView.self, from: Data(json.utf8))
        #expect(config.effort == "high")
        #expect(config.maxContextTokens == 8192)
    }

    @Test func purposeConfigToleratesAbsentMaxContextTokens() throws {
        let json = #"{"connection":"bedrock","model":"zai.glm-5"}"#
        let config = try JSONDecoder().decode(PurposeConfigView.self, from: Data(json.utf8))
        #expect(config.effort == nil)
        #expect(config.maxContextTokens == nil)
    }

    @Test func knowledgeEntry() throws {
        let json = """
        {"id":"k1","content":"remember this","tags":["x","y"],"created_at":"2026-01-01","updated_at":"2026-01-02"}
        """
        let entry = try JSONDecoder().decode(KnowledgeEntry.self, from: Data(json.utf8))
        #expect(entry.id == "k1")
        #expect(entry.content == "remember this")
        #expect(entry.tags == ["x", "y"])
    }

    @Test func commandResultHeadOk() throws {
        let json = #"{"type":"command_result","request_id":"r1","ok":true,"result":{"connections":[]}}"#
        let head = try JSONDecoder().decode(CommandResultHead.self, from: Data(json.utf8))
        #expect(head.type == "command_result")
        #expect(head.requestID == "r1")
        #expect(head.ok)
        #expect(head.error == nil)
    }

    @Test func commandResultHeadError() throws {
        let json = #"{"type":"command_result","request_id":"r2","ok":false,"error":"nope"}"#
        let head = try JSONDecoder().decode(CommandResultHead.self, from: Data(json.utf8))
        #expect(head.ok == false)
        #expect(head.error == "nope")
    }

    @Test func commandResultEnvelopeUnwrapsPayload() throws {
        struct ConnectionsPayload: Decodable { let connections: [ConnectionView] }
        let json = """
        {"type":"command_result","request_id":"r","ok":true,"result":{"connections":[{"id":"default","connector_type":"ollama","display_label":"d","availability":{"status":"ok"},"has_credentials":true}]}}
        """
        let env = try JSONDecoder().decode(CommandResultEnvelope<ConnectionsPayload>.self, from: Data(json.utf8))
        #expect(env.result?.connections.count == 1)
        #expect(env.result?.connections.first?.id == "default")
    }
}
