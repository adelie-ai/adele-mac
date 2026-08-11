import AdeleCore
import SwiftUI

/// What the open conversation's tools cost it (desktop-assistant#599).
///
/// Reachable from the conversation rather than folded into an existing panel.
/// Once the Context Inspector lands (desktop-assistant#588 / #589) this belongs
/// beside it as a tab; standing alone until then lets it ship independently.
struct ToolUsageView: View {
    let conversationID: String

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [ToolUsage] = []
    @State private var axis: ToolUsageReport.Axis = .tokens
    @State private var loadError: String?
    @State private var loaded = false
    /// Namespaces the user folded away. Collapsed rather than expanded state is
    /// stored, so a group that appears after a re-read starts open.
    @State private var collapsed: Set<String> = []

    private var report: ToolUsageReport {
        ToolUsageReport(rows: rows, sortedBy: axis)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 560, minHeight: 420)
        .task(id: conversationID) { await load() }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tool cost").font(.headline)
                Spacer()
                Picker("Sort by", selection: $axis) {
                    ForEach(ToolUsageReport.Axis.allCases, id: \.self) { axis in
                        Text(axis.label).tag(axis)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Rank tools by what they cost, or by how often they ran")
            }
            if !report.isEmpty {
                Text(totalsLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var totalsLine: String {
        let tools = report.distinctTools == 1 ? "1 tool" : "\(report.distinctTools) tools"
        let calls = report.totalCalls == 1 ? "1 call" : "\(report.totalCalls) calls"
        return "\(tools) · \(calls) · \(formatted(report.totalTokens)) tokens"
    }

    // MARK: Body

    @ViewBuilder private var content: some View {
        if let loadError {
            ContentUnavailableView(
                "Could not read tool cost",
                systemImage: "exclamationmark.triangle",
                description: Text(loadError))
        } else if !loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if report.isEmpty {
            // Never an error, and never an empty chart that reads as broken.
            ContentUnavailableView(
                "No tool calls in this conversation",
                systemImage: "wrench.and.screwdriver",
                description: Text("Tools this conversation ran, and what they cost, appear here."))
        } else {
            List {
                ForEach(report.groups) { group in
                    Section(isExpanded: expansion(of: group.namespace)) {
                        ForEach(group.rows) { row in
                            ToolUsageRow(row: row, report: report)
                        }
                    } header: {
                        HStack {
                            Text(group.namespace)
                            Spacer()
                            Text(subtotal(of: group))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    /// A group's open/closed binding. The subtotal stays visible either way, so
    /// folding a server away does not hide what it cost.
    private func expansion(of namespace: String) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(namespace) },
            set: { isExpanded in
                if isExpanded {
                    collapsed.remove(namespace)
                } else {
                    collapsed.insert(namespace)
                }
            })
    }

    private func subtotal(of group: ToolUsageReport.Group) -> String {
        switch axis {
        case .tokens: return "\(formatted(group.totalTokens)) tokens"
        case .calls: return group.totalCalls == 1 ? "1 call" : "\(group.totalCalls) calls"
        }
    }

    // MARK: Loading

    private func load() async {
        loaded = false
        loadError = nil
        do {
            rows = try await model.core.toolUsage(conversationID: conversationID)
        } catch {
            // An empty answer means "no tool calls" and is handled above; this
            // is a real failure to ask, so it must not read as a quiet zero.
            loadError = error.localizedDescription
        }
        loaded = true
    }
}

/// One tool's row: its figure, a bar proportional to the active axis, and what
/// the figure does not say.
private struct ToolUsageRow: View {
    let row: ToolUsage
    let report: ToolUsageReport

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(row.toolName)
                if let tier = row.tier {
                    TierChip(tier: tier)
                }
                Spacer()
                // Both figures always, whichever ranks: the axis that is not
                // sorted is still the one that explains the other.
                Text("\(formatted(row.resultTokens)) tokens")
                    .monospacedDigit()
                    .foregroundStyle(report.sortedBy == .tokens ? .primary : .secondary)
                Text("·").foregroundStyle(.secondary)
                Text(row.callCount == 1 ? "1 call" : "\(row.callCount) calls")
                    .monospacedDigit()
                    .foregroundStyle(report.sortedBy == .calls ? .primary : .secondary)
            }
            .font(.callout)

            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(.tint)
                    .frame(width: max(0, geometry.size.width * report.fraction(for: row)))
            }
            .frame(height: 6)

            HStack(spacing: 6) {
                // What distinguishes a steady trickle from one enormous dump.
                Text("largest \(formattedBytes(row.maxResultBytes))")
                Text("·")
                Text("resident \(formattedBytes(row.resultBytes))")
                if let note = ToolUsageReport.evictionNote(for: row) {
                    Text("·")
                    Text(note).foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

/// The provenance tier, shown only where it changes what a person can expect.
private struct TierChip: View {
    let tier: ToolTier

    var body: some View {
        Text(tier.label)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                tier.isGated ? AnyShapeStyle(.orange.opacity(0.18)) : AnyShapeStyle(.quaternary),
                in: Capsule())
            .help(
                tier.isGated
                    ? "Refused in a turn that has read outside content"
                    : "Runs even in a turn that has read outside content")
    }
}

/// Thousands separators, so a six-figure token count can be read at a glance.
private func formatted(_ value: UInt64) -> String {
    value.formatted(.number.grouping(.automatic))
}

private func formattedBytes(_ value: UInt64) -> String {
    value.formatted(.byteCount(style: .memory))
}
