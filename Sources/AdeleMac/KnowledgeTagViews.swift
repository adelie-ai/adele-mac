import AdeleCore
import SwiftUI

// Presentation for the knowledge base's two-level tag scheme (#513): *kind*
// tags say what sort of fact an entry is (`preference`, `architecture`), *facet*
// tags qualify it (`project:adelie-ai`, `topic:deploy`). Rendering them as one
// flat list loses that distinction, so kinds and facets get different chips and
// the editor edits them in separate fields.

/// The chip row under an entry: kind chips first, then facet chips.
struct KnowledgeTagChips: View {
    let entry: KnowledgeEntry

    var body: some View {
        if !entry.tags.isEmpty {
            // Wraps so a heavily-tagged entry doesn't clip its facets.
            FlowLayout(spacing: 4) {
                ForEach(entry.kindTags) { tag in
                    KindChip(name: tag.value)
                }
                ForEach(entry.facetTags) { tag in
                    FacetChip(facet: tag.facet ?? "", value: tag.value)
                }
            }
        }
    }
}

/// A bare kind tag.
struct KindChip: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

/// A `facet:value` tag: the facet name is de-emphasised so the value reads first.
struct FacetChip: View {
    let facet: String
    let value: String

    var body: some View {
        HStack(spacing: 3) {
            Text(facet)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.medium)
        }
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.accentColor.opacity(0.16), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.35)))
        .help("\(facet): \(value)")
    }
}

/// The editor's tag input: one field per level, plus a live preview of exactly
/// what will be written (tags are normalized on the way out, so the preview is
/// the honest answer to "what did I just save?").
struct KnowledgeTagFields: View {
    @Binding var kindsText: String
    @Binding var facetsText: String

    private var preview: [String] { KnowledgeTag.combine(kinds: kindsText, facets: facetsText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Kinds (comma-separated, e.g. preference, architecture)", text: $kindsText)
                .textFieldStyle(.roundedBorder)
            TextField("Facets (comma-separated facet:value, e.g. project:adelie-ai)", text: $facetsText)
                .textFieldStyle(.roundedBorder)
            if !preview.isEmpty {
                HStack(spacing: 4) {
                    Text("Saved as")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(preview.joined(separator: "  "))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}

/// Minimal wrapping HStack — chips flow onto as many rows as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = layout(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for row in layout(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layout(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let advance = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, advance > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
