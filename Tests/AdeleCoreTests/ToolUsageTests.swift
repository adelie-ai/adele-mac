import Foundation
import Testing

@testable import AdeleCore

/// Spec for the per-conversation tool-usage cost view (desktop-assistant#599).
///
/// The point of the view is cost analysis, and two axes are independently
/// material: frequency (forty calls is a signal even when each result is tiny)
/// and payload (one enormous result is the usual cause of a blown budget, and a
/// count-ordered list ranks it last). So the report is sortable by either, and
/// most of what follows is about keeping both readings honest.
@Suite struct ToolUsageTests {
    // MARK: Fixtures

    /// A `ToolUsageView` as the daemon sends it. Built as JSON because the type
    /// mirrors the wire form, which keeps the fixture honest about field names.
    private func usage(
        _ toolName: String,
        namespace: String? = nil,
        tier: String? = nil,
        calls: UInt32 = 1,
        bytes: UInt64 = 0,
        tokens: UInt64 = 0,
        maxBytes: UInt64 = 0,
        evicted: UInt32 = 0,
        firstUsedAt: String? = nil,
        lastUsedAt: String? = nil
    ) throws -> ToolUsage {
        var fields: [String: Any] = [
            "tool_name": toolName,
            "call_count": calls,
            "result_bytes": bytes,
            "result_tokens": tokens,
            "max_result_bytes": maxBytes,
            "evicted_results": evicted,
            "first_ordinal": 1,
            "last_ordinal": 2,
        ]
        if let namespace { fields["namespace"] = namespace }
        if let tier { fields["tool_tier"] = tier }
        if let firstUsedAt { fields["first_used_at"] = firstUsedAt }
        if let lastUsedAt { fields["last_used_at"] = lastUsedAt }
        let data = try JSONSerialization.data(withJSONObject: fields)
        return try JSONDecoder().decode(ToolUsage.self, from: data)
    }

    /// The chatty tool: many calls, small results.
    private func chatty() throws -> ToolUsage {
        try usage("search", namespace: "web", calls: 40, bytes: 4_000, tokens: 1_000, maxBytes: 200)
    }

    /// The heavy tool: one call, an enormous result.
    private func heavy() throws -> ToolUsage {
        try usage(
            "read_file", namespace: "fileio", calls: 1, bytes: 400_000, tokens: 100_000,
            maxBytes: 400_000)
    }

    // MARK: Decoding

    /// The wire names differ from the Swift ones, so the mapping is asserted
    /// rather than assumed.
    @Test func theWireFieldsDecodeOntoTheSwiftProperties() throws {
        let row = try usage(
            "read_file", namespace: "fileio", tier: "read", calls: 3, bytes: 900, tokens: 225,
            maxBytes: 700, evicted: 2, firstUsedAt: "2026-08-01T10:00:00Z",
            lastUsedAt: "2026-08-01T11:00:00Z")
        #expect(row.toolName == "read_file")
        #expect(row.namespace == "fileio")
        #expect(row.callCount == 3)
        #expect(row.resultBytes == 900)
        #expect(row.resultTokens == 225)
        #expect(row.maxResultBytes == 700)
        #expect(row.evictedResults == 2)
        #expect(row.firstOrdinal == 1)
        #expect(row.lastOrdinal == 2)
        #expect(row.firstUsedAt == "2026-08-01T10:00:00Z")
        #expect(row.lastUsedAt == "2026-08-01T11:00:00Z")
    }

    /// Every optional field may be absent. A row with no namespace, no tier and
    /// no timestamps must decode, because messages that predate UUIDv7 ids carry
    /// no times and a daemon older than the provenance gate sends no tier.
    @Test func aRowWithNoOptionalFieldsDecodes() throws {
        let row = try usage("bare")
        #expect(row.namespace == nil)
        #expect(row.tier == nil)
        #expect(row.firstUsedAt == nil)
        #expect(row.lastUsedAt == nil)
    }

    /// A tier this build does not know reads as unclassified rather than
    /// failing the frame - the same rule the daemon states for its own decode.
    @Test func anUnknownTierReadsAsUnclassified() throws {
        #expect(try usage("t", tier: "read").tier == .read)
        #expect(try usage("t", tier: "network_egress").tier == .egress)
        #expect(try usage("t", tier: "code_execution").tier == .execution)
        #expect(try usage("t", tier: "something_new_in_2027").tier == .unclassified)
    }

    /// Only some tiers can be refused mid-turn. That is the whole reason to show
    /// the tier at all, so the split is pinned rather than left to the renderer.
    @Test func onlySomeTiersAreRefusable() {
        #expect(ToolTier.read.isGated == false)
        #expect(ToolTier.present.isGated == false)
        #expect(ToolTier.mutate.isGated)
        #expect(ToolTier.egress.isGated)
        #expect(ToolTier.execution.isGated)
        #expect(ToolTier.unclassified.isGated, "an unknown tier is refusable, which is the safe reading")
    }

    // MARK: Sorting - the two axes

    /// By token cost, the infrequent-but-huge tool ranks first. This is the
    /// "what ate my context" reading, and it is the default.
    @Test func sortingByTokenCostPutsTheHugeToolFirst() throws {
        let report = ToolUsageReport(rows: [try chatty(), try heavy()], sortedBy: .tokens)
        #expect(report.ranked.map(\.toolName) == ["read_file", "search"])
    }

    /// By call count, the chatty tool ranks first. A retry storm is a signal
    /// even when every result is tiny, and the token ordering buries it.
    @Test func sortingByCallCountPutsTheChattyToolFirst() throws {
        let report = ToolUsageReport(rows: [try chatty(), try heavy()], sortedBy: .calls)
        #expect(report.ranked.map(\.toolName) == ["search", "read_file"])
    }

    /// Token cost is the default axis.
    @Test func theDefaultAxisIsTokenCost() throws {
        let report = ToolUsageReport(rows: [try chatty(), try heavy()])
        #expect(report.sortedBy == .tokens)
        #expect(report.ranked.first?.toolName == "read_file")
    }

    /// Two tools with the same figure order by name, so the list does not
    /// reshuffle between openings of the same conversation.
    @Test func aTieOrdersByNameSoTheListIsStable() throws {
        let rows = [
            try usage("zebra", tokens: 10),
            try usage("alpha", tokens: 10),
            try usage("middle", tokens: 10),
        ]
        #expect(
            ToolUsageReport(rows: rows, sortedBy: .tokens).ranked.map(\.toolName)
                == ["alpha", "middle", "zebra"])
    }

    // MARK: Bars

    /// A bar is proportional to the sorted axis, so re-sorting visibly re-ranks
    /// rather than leaving the bars in their old order.
    @Test func barsFollowTheSortedAxis() throws {
        let rows = [try chatty(), try heavy()]
        let byTokens = ToolUsageReport(rows: rows, sortedBy: .tokens)
        #expect(byTokens.fraction(for: try heavy()) == 1.0)
        // 1,000 of 100,000 tokens.
        #expect(abs(byTokens.fraction(for: try chatty()) - 0.01) < 0.0001)

        let byCalls = ToolUsageReport(rows: rows, sortedBy: .calls)
        #expect(byCalls.fraction(for: try chatty()) == 1.0)
        // 1 of 40 calls.
        #expect(abs(byCalls.fraction(for: try heavy()) - 0.025) < 0.0001)
    }

    /// Every row measuring zero on the sorted axis draws no bar, rather than a
    /// full one from dividing by zero.
    @Test func anAllZeroAxisDrawsNoBars() throws {
        let report = ToolUsageReport(rows: [try usage("a"), try usage("b")], sortedBy: .tokens)
        #expect(report.fraction(for: try usage("a")) == 0)
    }

    // MARK: Namespace grouping

    /// Groups carry their own subtotals, which answers "which server is this
    /// session leaning on".
    @Test func namespaceGroupsCarrySubtotals() throws {
        let rows = [
            try usage("search", namespace: "web", calls: 40, tokens: 1_000),
            try usage("fetch", namespace: "web", calls: 2, tokens: 500),
            try usage("read_file", namespace: "fileio", calls: 1, tokens: 100_000),
        ]
        let groups = ToolUsageReport(rows: rows, sortedBy: .tokens).groups
        let web = try #require(groups.first { $0.namespace == "web" })
        #expect(web.totalCalls == 42)
        #expect(web.totalTokens == 1_500)
        #expect(web.rows.count == 2)
    }

    /// Groups themselves rank by the sorted axis, so the heaviest server is at
    /// the top for the same reason the heaviest tool is.
    @Test func groupsRankByTheSortedAxis() throws {
        let rows = [
            try usage("search", namespace: "web", calls: 40, tokens: 1_000),
            try usage("read_file", namespace: "fileio", calls: 1, tokens: 100_000),
        ]
        #expect(
            ToolUsageReport(rows: rows, sortedBy: .tokens).groups.map(\.namespace)
                == ["fileio", "web"])
        #expect(
            ToolUsageReport(rows: rows, sortedBy: .calls).groups.map(\.namespace)
                == ["web", "fileio"])
    }

    /// A tool the daemon could not attribute to a server is still shown, under a
    /// named bucket. Dropping it would understate the conversation's cost.
    @Test func anUnattributedToolGetsItsOwnGroup() throws {
        let groups = ToolUsageReport(rows: [try usage("mystery", tokens: 5)]).groups
        #expect(groups.count == 1)
        #expect(groups.first?.namespace == ToolUsageReport.unattributedNamespace)
        #expect(groups.first?.rows.first?.toolName == "mystery")
    }

    // MARK: Header totals

    /// The header counts distinct tools, total calls and total tokens.
    @Test func theHeaderTotalsTheWholeConversation() throws {
        let report = ToolUsageReport(rows: [try chatty(), try heavy()])
        #expect(report.distinctTools == 2)
        #expect(report.totalCalls == 41)
        #expect(report.totalTokens == 101_000)
    }

    /// An empty conversation totals zero rather than failing.
    @Test func anEmptyConversationTotalsZero() {
        let report = ToolUsageReport(rows: [])
        #expect(report.isEmpty)
        #expect(report.distinctTools == 0)
        #expect(report.totalCalls == 0)
        #expect(report.totalTokens == 0)
        #expect(report.groups.isEmpty)
    }

    // MARK: Evictions, reported honestly

    /// A tool with evicted results is marked as under-reported. The original
    /// size is not recoverable, so presenting resident bytes as the whole story
    /// would be a lie by omission.
    @Test func anEvictedToolIsMarkedAsUnderReported() throws {
        let row = try usage("read_file", evicted: 3)
        let note = try #require(ToolUsageReport.evictionNote(for: row))
        #expect(note.contains("3"))
        #expect(note.lowercased().contains("evicted"))
    }

    /// The note counts, so one eviction does not read as plural.
    @Test func aSingleEvictionReadsAsSingular() throws {
        let note = try #require(ToolUsageReport.evictionNote(for: try usage("t", evicted: 1)))
        #expect(note.contains("1 evicted result "), "got: \(note)")
    }

    /// A tool with no evictions carries no note, so the marker means something
    /// where it does appear.
    @Test func aToolWithNoEvictionsCarriesNoNote() throws {
        #expect(ToolUsageReport.evictionNote(for: try usage("t", evicted: 0)) == nil)
    }

    // MARK: The command

    /// The query goes out under the name the daemon defines.
    @Test func theQueryBuildsTheDaemonsCommand() throws {
        let json = try #require(
            JSONSerialization.jsonObject(
                with: Data(AdeleCommand.getToolUsage(conversationID: "c1").utf8))
                as? [String: Any])
        let payload = try #require(json["get_tool_usage"] as? [String: Any])
        #expect(payload["conversation_id"] as? String == "c1")
    }
}
