import Testing
import Foundation
@testable import AdeleCore

/// Spec: the knowledge-base surface added in adele-mac#6 — the
/// `start_knowledge_maintenance` wire shape and its `MaintenanceTaskStarted`
/// reply, the daemon's two-level (kind + facet) tag scheme with write-path
/// normalization, and forward/backward-compatible decoding of `KnowledgeEntryView`.
///
/// The normalization cases mirror `desktop-assistant`'s
/// `crates/storage/src/tag_normalize.rs` one-for-one: the daemon normalizes on
/// write, so a client that normalizes differently would show one tag before a
/// refetch and another after.
@Suite struct KnowledgeTests {
    private func object(_ json: String) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try #require(value as? [String: Any])
    }

    // MARK: start_knowledge_maintenance

    @Test func maintenanceOpRawValuesMatchApiModel() {
        // api-model `MaintenanceOp` is `#[serde(rename_all = "snake_case")]`.
        #expect(KnowledgeMaintenanceOp.extraction.rawValue == "extraction")
        #expect(KnowledgeMaintenanceOp.consolidation.rawValue == "consolidation")
        #expect(KnowledgeMaintenanceOp.recalculateEmbeddings.rawValue == "recalculate_embeddings")
        #expect(KnowledgeMaintenanceOp.allCases.count == 3)
    }

    @Test func startKnowledgeMaintenanceShape() throws {
        for op in KnowledgeMaintenanceOp.allCases {
            let json = AdeleCommand.startKnowledgeMaintenance(op)
            let p = try #require((try object(json))["start_knowledge_maintenance"] as? [String: Any])
            #expect(p["op"] as? String == op.rawValue)
            #expect(p.count == 1, "the command carries only `op`")
        }
    }

    @Test func maintenanceTaskStartedDecodes() throws {
        let json = #"{"type":"command_result","request_id":"r","ok":true,"result":{"task_id":"t-42"}}"#
        let env = try JSONDecoder().decode(
            CommandResultEnvelope<MaintenanceTaskStartedPayload>.self, from: Data(json.utf8)
        )
        #expect(env.result?.task_id == "t-42")
    }

    /// An older daemon that doesn't know the command replies `Ack` (a bare
    /// string result) rather than `MaintenanceTaskStarted`; that must surface as
    /// "no task id", not a decode crash.
    @Test func maintenanceTaskStartedAbsentOnOlderDaemon() {
        let json = #"{"type":"command_result","request_id":"r","ok":true,"result":"ack"}"#
        let env = try? JSONDecoder().decode(
            CommandResultEnvelope<MaintenanceTaskStartedPayload>.self, from: Data(json.utf8)
        )
        #expect(env?.result?.task_id == nil)
    }

    /// The destructive/expensive passes must be gated behind a confirmation:
    /// consolidation prunes+merges rows, recalculation re-embeds the whole KB.
    @Test func destructiveOpsRequireConfirmation() {
        #expect(KnowledgeMaintenanceOp.extraction.needsConfirmation == false)
        #expect(KnowledgeMaintenanceOp.consolidation.needsConfirmation)
        #expect(KnowledgeMaintenanceOp.recalculateEmbeddings.needsConfirmation)
        for op in KnowledgeMaintenanceOp.allCases {
            #expect(!op.title.isEmpty)
            #expect(!op.detail.isEmpty)
        }
    }

    // MARK: tag normalization (mirrors storage/src/tag_normalize.rs)

    @Test func lowercasesAndTrimsKindTags() {
        #expect(KnowledgeTag.normalize("Preference") == "preference")
        #expect(KnowledgeTag.normalize("  Memory  ") == "memory")
        #expect(KnowledgeTag.normalize("INSTRUCTION") == "instruction")
    }

    @Test func collapsesInternalWhitespaceToDash() {
        #expect(KnowledgeTag.normalize("multi word tag") == "multi-word-tag")
        #expect(KnowledgeTag.normalize("multi   word\ttag") == "multi-word-tag")
    }

    @Test func preservesFacetColonAndNormalizesBothHalves() {
        #expect(KnowledgeTag.normalize("project:Adelie-AI") == "project:adelie-ai")
        #expect(KnowledgeTag.normalize("Project: Adelie AI") == "project:adelie-ai")
        #expect(KnowledgeTag.normalize("topic:Deploy") == "topic:deploy")
        #expect(KnowledgeTag.normalize("project:Adelie-AI") != "project-adelie-ai")
    }

    @Test func splitsOnFirstColonOnly() {
        #expect(KnowledgeTag.normalize("Topic:Release:2026") == "topic:release:2026")
    }

    @Test func leadingColonIsNotAFacet() {
        #expect(KnowledgeTag.normalize(":deploy") == ":deploy")
        #expect(KnowledgeTag.parse(":deploy").facet == nil)
    }

    @Test func normalizeListDedupsPreservingOrder() {
        #expect(KnowledgeTag.normalize(["Preference", " Memory "]) == ["preference", "memory"])
        #expect(
            KnowledgeTag.normalize(["instruction", "Instruction", "project:X", "PROJECT:x"])
                == ["instruction", "project:x"]
        )
    }

    @Test func normalizeListDropsEmpty() {
        #expect(KnowledgeTag.normalize(["", "   ", "ok"]) == ["ok"])
    }

    // MARK: kind + facet round-trip

    @Test func parseSplitsKindFromFacet() {
        let kind = KnowledgeTag.parse("Preference")
        #expect(kind.facet == nil)
        #expect(kind.value == "preference")
        #expect(kind.isFacet == false)
        #expect(kind.normalized == "preference")

        let facet = KnowledgeTag.parse("Project: Adelie AI")
        #expect(facet.facet == "project")
        #expect(facet.value == "adelie-ai")
        #expect(facet.isFacet)
        #expect(facet.normalized == "project:adelie-ai")
    }

    /// The editor splits an entry's flat tag list into two fields and rejoins
    /// them on save; that must be lossless for already-normalized tags.
    @Test func tagsRoundTripThroughKindAndFacetFields() {
        let stored = ["preference", "project:adelie-ai", "architecture", "topic:deploy"]
        let entry = makeEntry(tags: stored)
        #expect(entry.kindTags.map(\.normalized) == ["preference", "architecture"])
        #expect(entry.facetTags.map(\.normalized) == ["project:adelie-ai", "topic:deploy"])

        let fields = entry.tagFields
        #expect(fields.kinds == "preference, architecture")
        #expect(fields.facets == "project:adelie-ai, topic:deploy")

        let rejoined = KnowledgeTag.combine(kinds: fields.kinds, facets: fields.facets)
        #expect(Set(rejoined) == Set(stored))
        // Kinds come first, so a second round trip is a fixed point.
        #expect(makeEntry(tags: rejoined).tagFields == fields)
    }

    /// A user typing into the two fields gets the same normalization the daemon
    /// applies, whichever field a facet-shaped tag lands in.
    @Test func combineNormalizesAndDedupsAcrossFields() {
        #expect(
            KnowledgeTag.combine(kinds: " Preference , Architecture ", facets: "Project: Adelie AI")
                == ["preference", "architecture", "project:adelie-ai"]
        )
        #expect(KnowledgeTag.combine(kinds: "", facets: "") == [])
        // A facet typed into the kinds field is still stored as a facet.
        #expect(KnowledgeTag.combine(kinds: "topic:Deploy", facets: "") == ["topic:deploy"])
    }

    @Test func facetTagsGroupByFacetName() {
        let entry = makeEntry(tags: ["preference", "project:a", "topic:x", "project:b"])
        let groups = entry.facetGroups
        #expect(groups.map(\.facet) == ["project", "topic"], "first-seen facet order is preserved")
        #expect(groups[0].values == ["a", "b"])
        #expect(groups[1].values == ["x"])
    }

    // MARK: write-path normalization

    @Test func createKnowledgeNormalizesTags() throws {
        let json = AdeleCommand.createKnowledge(
            content: "c", tags: ["Preference", "Project: Adelie AI", "  ", "preference"]
        )
        let p = try #require((try object(json))["create_knowledge_entry"] as? [String: Any])
        #expect(p["content"] as? String == "c")
        #expect(p["tags"] as? [String] == ["preference", "project:adelie-ai"])
    }

    @Test func updateKnowledgeNormalizesTags() throws {
        let json = AdeleCommand.updateKnowledge(
            id: "k1", content: "c", tags: ["TOPIC:Deploy", "memory"]
        )
        let p = try #require((try object(json))["update_knowledge_entry"] as? [String: Any])
        #expect(p["id"] as? String == "k1")
        #expect(p["tags"] as? [String] == ["topic:deploy", "memory"])
    }

    // MARK: KnowledgeEntryView decoding

    /// `metadata` is `#[serde(default)]` on the daemon and unknown to us; extra
    /// fields must not break decoding, and a daemon that omits `tags` entirely
    /// (pre-#513 shapes) must decode to an empty list rather than throwing.
    @Test func knowledgeEntryToleratesExtraAndMissingFields() throws {
        let withMetadata = """
        {"id":"k1","content":"c","tags":["preference"],"metadata":{"scope":{"project":"adelie-ai"}},\
        "created_at":"2026-01-01","updated_at":"2026-01-02","future_field":7}
        """
        let entry = try JSONDecoder().decode(KnowledgeEntry.self, from: Data(withMetadata.utf8))
        #expect(entry.tags == ["preference"])

        let noTags = #"{"id":"k2","content":"c","created_at":"a","updated_at":"b"}"#
        let bare = try JSONDecoder().decode(KnowledgeEntry.self, from: Data(noTags.utf8))
        #expect(bare.tags == [])
        #expect(bare.kindTags.isEmpty)
        #expect(bare.facetTags.isEmpty)
    }

    // MARK: knowledge_changed view event

    @Test func knowledgeChangedEventDecodes() throws {
        let event = try JSONDecoder().decode(
            ViewEvent.self, from: Data(#"{"type":"knowledge_changed"}"#.utf8)
        )
        guard case .knowledgeChanged = event else {
            Issue.record("expected .knowledgeChanged, got \(event)"); return
        }
    }

    private func makeEntry(tags: [String]) -> KnowledgeEntry {
        let json = """
        {"id":"k","content":"c","tags":\(String(
            decoding: try! JSONSerialization.data(withJSONObject: tags), as: UTF8.self
        )),"created_at":"a","updated_at":"b"}
        """
        return try! JSONDecoder().decode(KnowledgeEntry.self, from: Data(json.utf8))
    }
}
