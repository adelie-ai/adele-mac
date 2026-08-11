import Foundation

/// How the tool-provenance gate classifies a tool (desktop-assistant#741).
///
/// The wire form is a lower-case string rather than a closed set, because a tier
/// a newer daemon added must not fail a whole frame. An unrecognized value reads
/// as ``unclassified``, which is the safe reading: treat it as something that
/// can be refused.
public enum ToolTier: Sendable, Hashable {
    /// Reads state and changes nothing.
    case read
    /// Delivers output to the user's own session, or changes how it is shown.
    case present
    /// Changes durable state, including the assistant's own memory.
    case mutate
    /// Can send bytes to a destination chosen at call time.
    case egress
    /// Runs a command, a script, or an agent chosen at call time.
    case execution
    /// No classification, or a tier this build does not know.
    case unclassified

    public init(wire: String) {
        switch wire {
        case "read": self = .read
        case "present": self = .present
        case "mutate": self = .mutate
        case "network_egress": self = .egress
        case "code_execution": self = .execution
        default: self = .unclassified
        }
    }

    /// Whether a call to a tool in this tier is refused once the turn has taken
    /// in externally-controlled content.
    ///
    /// This is the only reason the tier is worth showing: it answers which of
    /// the tools a conversation leans on will stop working in a turn that read
    /// outside content.
    public var isGated: Bool {
        switch self {
        case .read, .present: return false
        case .mutate, .egress, .execution, .unclassified: return true
        }
    }

    /// Short label for a row chip.
    public var label: String {
        switch self {
        case .read: return "read"
        case .present: return "present"
        case .mutate: return "mutate"
        case .egress: return "network"
        case .execution: return "execute"
        case .unclassified: return "unclassified"
        }
    }
}

/// What one tool cost a conversation (mirrors api-model `ToolUsageView`).
///
/// Read-only and derived, so it is safe to ask for at any time and it answers
/// retroactively.
public struct ToolUsage: Decodable, Hashable, Sendable, Identifiable {
    public let toolName: String
    /// `builtin`, or the MCP server hosting the tool, when the daemon could
    /// resolve it.
    public let namespace: String?
    /// How the provenance gate classifies the tool; absent on a daemon older
    /// than that gate.
    public let tier: ToolTier?
    /// Invocations the model requested. Failures and never-executed calls count:
    /// the request is what spent the round.
    public let callCount: UInt32
    /// Result bytes still resident in the conversation.
    public let resultBytes: UInt64
    /// Estimated tokens for ``resultBytes``, using the context budget's own
    /// estimator so the two figures are comparable. Bytes are measured, tokens
    /// are estimated.
    public let resultTokens: UInt64
    /// Largest single resident result. This is what tells a steady trickle from
    /// one enormous dump.
    public let maxResultBytes: UInt64
    /// Stored results the model now reads as a compaction pointer rather than as
    /// the tool's own output. See ``ToolUsageReport/evictionNote(for:)``.
    public let evictedResults: UInt32
    /// Message ordinals of the first and last call.
    public let firstOrdinal: Int32
    public let lastOrdinal: Int32
    /// Wall-clock of the first and last call. Recovered from the message UUIDv7
    /// id, so absent for messages that predate those ids.
    public let firstUsedAt: String?
    public let lastUsedAt: String?

    /// Unique within one conversation's report: the daemon aggregates per tool.
    public var id: String { "\(namespace ?? "")/\(toolName)" }

    /// The server this tool belongs to, or `nil` when nothing says.
    ///
    /// Prefers what the daemon reported. Falls back to the namespace encoded in
    /// the tool's own exposed name, because the daemon does not fill the field
    /// in yet (desktop-assistant#1261) and its MCP executor builds that name as
    /// `"<namespace>__<tool>"`. So this reads the daemon's own encoding rather
    /// than guessing, and it retires itself the day the field arrives.
    ///
    /// A name with no separator, or one that begins with it, resolves to `nil`:
    /// an empty group heading is worse than an honest unattributed one.
    public var resolvedNamespace: String? {
        if let namespace, !namespace.isEmpty { return namespace }
        guard let separator = toolName.range(of: Self.namespaceSeparator) else { return nil }
        let prefix = toolName[toolName.startIndex..<separator.lowerBound]
        return prefix.isEmpty ? nil : String(prefix)
    }

    /// How the daemon's MCP executor joins a server's namespace to a tool name.
    static let namespaceSeparator = "__"

    enum CodingKeys: String, CodingKey {
        case namespace
        case toolName = "tool_name"
        case toolTier = "tool_tier"
        case callCount = "call_count"
        case resultBytes = "result_bytes"
        case resultTokens = "result_tokens"
        case maxResultBytes = "max_result_bytes"
        case evictedResults = "evicted_results"
        case firstOrdinal = "first_ordinal"
        case lastOrdinal = "last_ordinal"
        case firstUsedAt = "first_used_at"
        case lastUsedAt = "last_used_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toolName = try c.decode(String.self, forKey: .toolName)
        namespace = try c.decodeIfPresent(String.self, forKey: .namespace)
        tier = try c.decodeIfPresent(String.self, forKey: .toolTier).map(ToolTier.init(wire:))
        callCount = try c.decode(UInt32.self, forKey: .callCount)
        resultBytes = try c.decode(UInt64.self, forKey: .resultBytes)
        resultTokens = try c.decode(UInt64.self, forKey: .resultTokens)
        maxResultBytes = try c.decode(UInt64.self, forKey: .maxResultBytes)
        evictedResults = try c.decode(UInt32.self, forKey: .evictedResults)
        firstOrdinal = try c.decode(Int32.self, forKey: .firstOrdinal)
        lastOrdinal = try c.decode(Int32.self, forKey: .lastOrdinal)
        firstUsedAt = try c.decodeIfPresent(String.self, forKey: .firstUsedAt)
        lastUsedAt = try c.decodeIfPresent(String.self, forKey: .lastUsedAt)
    }
}

/// One conversation's tool cost, ordered and grouped for reading.
///
/// # Why there are two orderings and not one
///
/// Frequency and payload are independently material, and each ordering buries
/// the other's signal. Forty calls to one tool is a retry storm or a search
/// loop, and it says so even when every result is tiny - but a token ordering
/// puts it near the bottom. One call returning half a megabyte is the usual
/// cause of a blown context budget, and a count ordering puts it last. So the
/// report sorts by either, and the bars follow whichever is active, so
/// re-sorting visibly re-ranks instead of leaving the old shape behind.
///
/// Token cost is the default, because "what ate my context" is the question
/// someone opens this view to answer.
public struct ToolUsageReport: Sendable {
    /// Which figure ranks the rows, the groups, and the bars.
    public enum Axis: String, Sendable, CaseIterable {
        case tokens
        case calls

        public var label: String {
            switch self {
            case .tokens: return "Token cost"
            case .calls: return "Call count"
            }
        }
    }

    /// The bucket for a tool nothing attributes to a server - neither the
    /// daemon's own field nor the tool's exposed name. Such a tool is still
    /// shown: dropping it would understate what the conversation spent.
    public static let unattributedNamespace = "Unattributed"

    /// One namespace's rows and its subtotals - "which server is this session
    /// leaning on".
    public struct Group: Sendable, Identifiable {
        public let namespace: String
        public let rows: [ToolUsage]
        public let totalCalls: UInt64
        public let totalTokens: UInt64

        public var id: String { namespace }
    }

    public let rows: [ToolUsage]
    public let sortedBy: Axis

    public init(rows: [ToolUsage], sortedBy: Axis = .tokens) {
        self.rows = rows
        self.sortedBy = sortedBy
    }

    public var isEmpty: Bool { rows.isEmpty }

    // MARK: Header totals

    public var distinctTools: Int { rows.count }
    public var totalCalls: UInt64 { rows.reduce(0) { $0 + UInt64($1.callCount) } }
    public var totalTokens: UInt64 { rows.reduce(0) { $0 + $1.resultTokens } }

    // MARK: Ordering

    /// Every row, heaviest first on the active axis.
    ///
    /// Ties break on the tool name, so a report opened twice for the same
    /// conversation lists its rows in the same order both times. Swift's `sort`
    /// is not stable, so without an explicit tiebreak equal rows could swap.
    public var ranked: [ToolUsage] {
        rows.sorted { lhs, rhs in
            let l = value(of: lhs), r = value(of: rhs)
            if l != r { return l > r }
            return lhs.toolName < rhs.toolName
        }
    }

    /// The rows grouped by namespace, groups and rows both heaviest first.
    public var groups: [Group] {
        var order: [String] = []
        var buckets: [String: [ToolUsage]] = [:]
        for row in ranked {
            let key = row.resolvedNamespace ?? Self.unattributedNamespace
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = []
            }
            buckets[key]?.append(row)
        }
        let built = order.map { key -> Group in
            let rows = buckets[key] ?? []
            return Group(
                namespace: key,
                rows: rows,
                totalCalls: rows.reduce(0) { $0 + UInt64($1.callCount) },
                totalTokens: rows.reduce(0) { $0 + $1.resultTokens })
        }
        return built.sorted { lhs, rhs in
            let l = value(of: lhs), r = value(of: rhs)
            if l != r { return l > r }
            return lhs.namespace < rhs.namespace
        }
    }

    // MARK: Bars

    /// How long a row's bar is, as a fraction of the heaviest row on the active
    /// axis.
    ///
    /// Zero when every row measures zero, rather than a full bar from dividing
    /// by nothing - a conversation whose tools returned nothing must not read as
    /// one where they returned everything.
    public func fraction(for row: ToolUsage) -> Double {
        let peak = rows.map(value(of:)).max() ?? 0
        guard peak > 0 else { return 0 }
        return Double(value(of: row)) / Double(peak)
    }

    // MARK: Evictions

    /// The under-reporting note for a row, or `nil` when it has none.
    ///
    /// A compacted result's original size is **not recoverable**, so
    /// ``ToolUsage/resultBytes`` is what the tool costs now, not what it cost.
    /// Presenting the resident figure as the whole story would understate the
    /// tool by an unknown amount, so a row with evictions says so. Peak cost is
    /// tracked in desktop-assistant#675; nothing here invents it.
    public static func evictionNote(for row: ToolUsage) -> String? {
        guard row.evictedResults > 0 else { return nil }
        let noun = row.evictedResults == 1 ? "result" : "results"
        return "\(row.evictedResults) evicted \(noun) - the real cost was higher"
    }

    // MARK: -

    private func value(of row: ToolUsage) -> UInt64 {
        switch sortedBy {
        case .tokens: return row.resultTokens
        case .calls: return UInt64(row.callCount)
        }
    }

    private func value(of group: Group) -> UInt64 {
        switch sortedBy {
        case .tokens: return group.totalTokens
        case .calls: return group.totalCalls
        }
    }
}
