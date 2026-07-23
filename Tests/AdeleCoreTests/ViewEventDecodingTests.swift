import Testing
import Foundation
@testable import AdeleCore

/// Spec: every FFI view-event tag decodes into the matching typed `ViewEvent`
/// case with its fields; unknown tags fall back to `.unknown` (forward-compat).
@Suite struct ViewEventDecodingTests {
    private func decode(_ json: String) throws -> ViewEvent {
        try JSONDecoder().decode(ViewEvent.self, from: Data(json.utf8))
    }

    @Test func chunk() throws {
        guard case .chunk(let text) = try decode(#"{"type":"chunk","text":"hi"}"#) else {
            Issue.record("expected .chunk"); return
        }
        #expect(text == "hi")
    }

    @Test func complete() throws {
        guard case .complete(let text) = try decode(#"{"type":"complete","text":"done"}"#) else {
            Issue.record("expected .complete"); return
        }
        #expect(text == "done")
    }

    @Test func connectedErrorCleared() throws {
        guard case .connected(let label) = try decode(#"{"type":"connected","label":"L"}"#) else {
            Issue.record("expected .connected"); return
        }
        #expect(label == "L")
        guard case .connectError(let message) = try decode(#"{"type":"connect_error","message":"boom"}"#) else {
            Issue.record("expected .connectError"); return
        }
        #expect(message == "boom")
        guard case .clientCleared = try decode(#"{"type":"client_cleared"}"#) else {
            Issue.record("expected .clientCleared"); return
        }
    }

    @Test func sendSensitive() throws {
        guard case .sendSensitive(let value) = try decode(#"{"type":"send_sensitive","value":false}"#) else {
            Issue.record("expected .sendSensitive"); return
        }
        #expect(value == false)
    }

    @Test func conversations() throws {
        let json = #"{"type":"conversations","items":[{"id":"c1","title":"First","message_count":3,"archived":false}]}"#
        guard case .conversations(let items) = try decode(json) else {
            Issue.record("expected .conversations"); return
        }
        #expect(items.count == 1)
        #expect(items[0].id == "c1")
        #expect(items[0].messageCount == 3)
        #expect(items[0].archived == false)
    }

    @Test func loadConversation() throws {
        let json = """
        {"type":"load_conversation","detail":{"id":"c1","title":"T","messages":[{"id":"m1","role":"user","content":"hi"}]}}
        """
        guard case .loadConversation(let detail) = try decode(json) else {
            Issue.record("expected .loadConversation"); return
        }
        #expect(detail.id == "c1")
        #expect(detail.messages.first?.role == "user")
        #expect(detail.messages.first?.content == "hi")
    }

    @Test func contextUsage() throws {
        let json = """
        {"type":"context_usage","usage":{"used_tokens":100,"budget_tokens":1000,"compaction_active":false,"fraction":0.1,"level":"green","readout":"0k / 1k (10%)"}}
        """
        guard case .contextUsage(let usage) = try decode(json) else {
            Issue.record("expected .contextUsage"); return
        }
        #expect(usage?.level == "green")
        #expect(usage?.readout == "0k / 1k (10%)")
        guard case .contextUsage(let none) = try decode(#"{"type":"context_usage","usage":null}"#) else {
            Issue.record("expected .contextUsage(nil)"); return
        }
        #expect(none == nil)
    }

    @Test func modelsAndDefaultModel() throws {
        let json = """
        {"type":"models","items":[{"connection_id":"default","connection_label":"default (ollama)","model":{"id":"llama3.2:1b","display_name":"Llama 3.2 1B","context_limit":4096,"capabilities":{"reasoning":false}}}]}
        """
        guard case .models(let items) = try decode(json) else { Issue.record("expected .models"); return }
        #expect(items.first?.connectionId == "default")
        #expect(items.first?.model.displayName == "Llama 3.2 1B")
        #expect(items.first?.id == "default/llama3.2:1b")

        let dm = #"{"type":"default_model","model":{"connection_id":"default","model_id":"llama3.2:1b"}}"#
        guard case .defaultModel(let model) = try decode(dm) else { Issue.record("expected .defaultModel"); return }
        #expect(model?.modelId == "llama3.2:1b")
    }

    @Test func taskEvents() throws {
        let started = """
        {"type":"task_started","task":{"id":"t1","kind":"subagent","status":"running","started_at":0,"title":"Research"}}
        """
        guard case .taskStarted(let task) = try decode(started) else { Issue.record("expected .taskStarted"); return }
        #expect(task.id == "t1")
        #expect(task.isActive)

        guard case .taskProgress(let id, let hint) = try decode(#"{"type":"task_progress","id":"t1","progress_hint":"50%"}"#) else {
            Issue.record("expected .taskProgress"); return
        }
        #expect(id == "t1")
        #expect(hint == "50%")
    }

    @Test func scratchpadAndSpeak() throws {
        let sp = """
        {"type":"scratchpad","notes":[{"id":"n1","key":"k","content":"c","note_type":"todo","done":true,"updated_at":"2026"}]}
        """
        guard case .scratchpad(let notes) = try decode(sp) else { Issue.record("expected .scratchpad"); return }
        #expect(notes.first?.noteType == "todo")
        #expect(notes.first?.done == true)

        guard case .speak(let text) = try decode(#"{"type":"speak","text":"hello"}"#) else {
            Issue.record("expected .speak"); return
        }
        #expect(text == "hello")

        guard case .adeleOutputDropdown(let level) = try decode(#"{"type":"adele_output_dropdown","level":"always"}"#) else {
            Issue.record("expected .adeleOutputDropdown"); return
        }
        #expect(level == "always")
    }

    @Test func unknownTagFallsBack() throws {
        guard case .unknown(let type) = try decode(#"{"type":"some_future_event","x":1}"#) else {
            Issue.record("expected .unknown"); return
        }
        #expect(type == "some_future_event")
    }

    /// The core's built-in MCP inventory (adele-mac#12). Decoded literally: these
    /// field names are the ABI, and a mismatch would blank the panel's built-in
    /// rows rather than fail loudly.
    @Test func mcpBuiltins() throws {
        let json = """
            {"type":"mcp_builtins","surface":"mac","servers":[\
            {"name":"fileio","namespace":"fileio","kind":"built_in","tool_count":9,\
            "overridden_by":null,"disabled_by_config":false},\
            {"name":"web","namespace":"web","kind":"built_in","tool_count":3,\
            "overridden_by":"web","disabled_by_config":true}]}
            """
        guard case .mcpBuiltins(let surface, let servers) = try decode(json) else {
            Issue.record("expected .mcpBuiltins"); return
        }
        #expect(surface == "mac", "the core echoes which surface it resolved")
        #expect(servers.count == 2)
        #expect(servers[0] == McpBuiltinServer(name: "fileio", namespace: "fileio", toolCount: 9))
        #expect(servers[1].overriddenBy == "web")
        #expect(servers[1].disabledByConfig)
    }

    /// A core built with no `mcp-*` feature answers with an empty list — the
    /// honest "none linked in", which must decode rather than be treated as
    /// malformed.
    @Test func mcpBuiltinsEmpty() throws {
        guard case .mcpBuiltins(let surface, let servers) =
            try decode(#"{"type":"mcp_builtins","surface":"kde","servers":[]}"#)
        else {
            Issue.record("expected .mcpBuiltins"); return
        }
        #expect(surface == "kde")
        #expect(servers.isEmpty)
    }

    @Test func scratchpadNoteDefaults() throws {
        let json = """
        {"type":"scratchpad","notes":[{"id":"n1","key":"k","content":"c","updated_at":"2026"}]}
        """
        guard case .scratchpad(let notes) = try decode(json) else { Issue.record("expected .scratchpad"); return }
        #expect(notes.first?.noteType == "note")
        #expect(notes.first?.done == false)
    }
}
