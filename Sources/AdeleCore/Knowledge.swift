import Foundation

// The knowledge base's two-level tag scheme and its on-demand maintenance
// passes. Both are daemon concepts mirrored here so the browser can render and
// write them without re-deriving the rules:
//
//   * tags — desktop-assistant #513 split KB tags into a *kind* (what sort of
//     fact this is: `preference`, `architecture`) and a *facet* (`facet:value`,
//     e.g. `project:adelie-ai`). Storage normalizes on write
//     (`crates/storage/src/tag_normalize.rs`); we normalize identically so what
//     the user typed and what a later refetch returns are the same string.
//   * maintenance — `Command::StartKnowledgeMaintenance { op }` triggers one of
//     the daemon's three background passes on demand. See
//     `docs/features/knowledge-maintenance.md`.

/// Which knowledge-maintenance pass `StartKnowledgeMaintenance` runs (mirrors
/// api-model `MaintenanceOp`, serialized snake_case).
public enum KnowledgeMaintenanceOp: String, CaseIterable, Sendable {
    /// Scan conversations for new facts (the fast "dreaming" pass) + archival.
    case extraction
    /// Holistic recompute/prune of the active knowledge base (the slow pass).
    case consolidation
    /// Force-recompute embeddings for EVERY active entry, regardless of
    /// model/freshness — the escape hatch for out-of-band corruption.
    case recalculateEmbeddings = "recalculate_embeddings"

    public var title: String {
        switch self {
        case .extraction: return "Extract Facts"
        case .consolidation: return "Consolidate"
        case .recalculateEmbeddings: return "Recalculate Embeddings"
        }
    }

    /// One-line description, shown as the menu item's help and in the
    /// confirmation dialog.
    public var detail: String {
        switch self {
        case .extraction:
            return "Scan recent conversations for durable facts and add them to the knowledge base."
        case .consolidation:
            return "Recompute the whole knowledge base with a stronger model, "
                + "merging duplicates and pruning entries it judges stale."
        case .recalculateEmbeddings:
            return "Re-embed every active entry from scratch. Routine model changes are "
                + "handled automatically — use this only to repair out-of-band damage."
        }
    }

    /// Whether triggering the pass needs an explicit confirmation. Consolidation
    /// rewrites and soft-deletes existing rows; recalculation re-embeds the whole
    /// base (expensive). Extraction only adds facts, so it runs directly.
    public var needsConfirmation: Bool {
        switch self {
        case .extraction: return false
        case .consolidation, .recalculateEmbeddings: return true
        }
    }
}

/// One knowledge-base tag, parsed into the daemon's two-level scheme: a bare
/// *kind* tag (`preference`) or a *facet* tag (`project:adelie-ai`).
///
/// Both halves are stored already-normalized, so `normalized` is exactly the
/// string the daemon will hold after a write.
public struct KnowledgeTag: Hashable, Identifiable, Sendable {
    /// The facet name (before the first colon), or `nil` for a kind tag.
    public let facet: String?
    /// The value — the whole tag for a kind tag, the part after the first colon
    /// for a facet tag (which may itself contain colons).
    public let value: String

    public init(facet: String?, value: String) {
        self.facet = facet
        self.value = value
    }

    public var isFacet: Bool { facet != nil }
    public var normalized: String { facet.map { "\($0):\(value)" } ?? value }
    public var id: String { normalized }

    /// Parse and normalize a raw tag. A tag is a facet only when there is a
    /// non-empty name before the first colon; a leading colon is a plain token
    /// (matching `tag_normalize::normalize_tag`).
    public static func parse(_ raw: String) -> KnowledgeTag {
        if let colon = raw.firstIndex(of: ":"),
           !raw[raw.startIndex..<colon].trimmingCharacters(in: .whitespaces).isEmpty {
            return KnowledgeTag(
                facet: normalizeToken(String(raw[raw.startIndex..<colon])),
                value: normalizeToken(String(raw[raw.index(after: colon)...]))
            )
        }
        return KnowledgeTag(facet: nil, value: normalizeToken(raw))
    }

    /// Normalize a single tag to the daemon's canonical form.
    public static func normalize(_ raw: String) -> String { parse(raw).normalized }

    /// Normalize a list, dropping empties and duplicates that collapse together
    /// while preserving first-seen order.
    public static func normalize(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for tag in tags {
            let norm = normalize(tag)
            guard !norm.isEmpty, seen.insert(norm).inserted else { continue }
            out.append(norm)
        }
        return out
    }

    /// Lowercase, trim, and collapse internal whitespace runs to single dashes
    /// (`tag_normalize::normalize_token`). Existing dashes are preserved.
    private static func normalizeToken(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace).joined(separator: "-").lowercased()
    }

    // MARK: Editor field <-> tag list

    /// Split one comma-separated editor field into raw tags (normalization
    /// happens in `combine`).
    public static func split(_ field: String) -> [String] {
        field.split(separator: ",").map(String.init)
    }

    /// The normalized tag list the editor's two fields produce. Kinds are listed
    /// before facets so the stored order matches how the chips render.
    public static func combine(kinds: String, facets: String) -> [String] {
        normalize(split(kinds) + split(facets))
    }
}

/// A facet name with every value the entry carries under it, for grouped display.
public struct KnowledgeFacetGroup: Identifiable, Hashable, Sendable {
    public let facet: String
    public let values: [String]
    public var id: String { facet }
}

extension KnowledgeEntry {
    /// The entry's tags parsed into the kind/facet scheme (order preserved).
    public var parsedTags: [KnowledgeTag] { tags.map(KnowledgeTag.parse) }

    /// Bare kind tags (`preference`, `architecture`, …).
    public var kindTags: [KnowledgeTag] { parsedTags.filter { !$0.isFacet } }

    /// `facet:value` tags (`project:adelie-ai`, `topic:deploy`, …).
    public var facetTags: [KnowledgeTag] { parsedTags.filter(\.isFacet) }

    /// The entry's tags split into the editor's two comma-separated fields.
    /// `KnowledgeTag.combine` is the inverse.
    public var tagFields: (kinds: String, facets: String) {
        (
            kindTags.map(\.normalized).joined(separator: ", "),
            facetTags.map(\.normalized).joined(separator: ", ")
        )
    }

    /// Facet tags collapsed by facet name, first-seen order.
    public var facetGroups: [KnowledgeFacetGroup] {
        var order: [String] = []
        var values: [String: [String]] = [:]
        for tag in facetTags {
            guard let facet = tag.facet else { continue }
            if values[facet] == nil {
                order.append(facet)
                values[facet] = []
            }
            values[facet]?.append(tag.value)
        }
        return order.map { KnowledgeFacetGroup(facet: $0, values: values[$0] ?? []) }
    }
}
