import Foundation

/// What a purposes row currently shows, lifted out of SwiftUI so the decision to
/// write is plain data rather than a question about when a change notification
/// fires. `nil` (or blank) on `connection`/`model` means the row has nothing
/// real selected — typically because its model list never loaded.
///
/// `effort` and `maxContextTokens` are carried, not edited, by the macOS UI:
/// `SetPurpose` is a full replace, so whatever the daemon last reported for the
/// fields this client does not surface has to be sent back unchanged.
public struct PurposeSelection: Hashable, Sendable {
    public var connection: String?
    public var model: String?
    /// "low" | "medium" | "high" | nil.
    public var effort: String?
    /// Per-purpose context-window override (desktop-assistant#51).
    public var maxContextTokens: UInt64?

    public init(
        connection: String?,
        model: String?,
        effort: String? = nil,
        maxContextTokens: UInt64? = nil
    ) {
        self.connection = connection
        self.model = model
        self.effort = effort
        self.maxContextTokens = maxContextTokens
    }

    /// The shape a menu pick produces: the user chose a connection+model, and
    /// every field this UI does not edit comes off the daemon's last reported
    /// binding so the write does not clobber it.
    public init(
        pick: (connection: String, model: String),
        carryingFrom lastKnown: PurposeConfigView?
    ) {
        self.init(
            connection: pick.connection,
            model: pick.model,
            effort: lastKnown?.effort,
            maxContextTokens: lastKnown?.maxContextTokens
        )
    }
}

/// Whether a purposes-row state is a write worth sending.
///
/// This is the Swift port of `planned_write` in adele-gtk's `purposes_tab.rs`
/// (adele-gtk#142 / PR #143). It is a pure function on purpose. GTK's earlier
/// attempt suppressed writes with a boolean flag held across its reconcile,
/// which only covered notifications delivered synchronously; anything arriving
/// after the reconcile returned found the flag cleared, re-emitted a
/// `SetPurpose`, and the resulting refresh reconciled again — a write loop that
/// ran at ~3 writes/sec until the socket dropped. Deciding from data instead of
/// from signal timing is what makes the loop structurally impossible, and it is
/// what makes both rules testable without a daemon or a UI.
public enum PurposeWrite {
    /// The literal that means "inherit from the interactive purpose". It is only
    /// meaningful when *both* sides of a binding carry it.
    public static let primarySentinel = "primary"

    /// Returns the config to send, or `nil` for "not a user-intended change,
    /// send nothing".
    ///
    /// `nil` is returned when:
    ///
    /// * `purpose` is not one of `AdeleCore.purposeKinds` — never invent a
    ///   binding for a purpose the daemon does not define;
    /// * either side has no real selection (blank or absent), because the model
    ///   list did not load and the UI cannot honestly represent a binding it
    ///   could not display;
    /// * the pair is mixed — a real connection with a `"primary"` model, or the
    ///   reverse. That is the shape that shipped as
    ///   `connection = "bedrock", model = "primary"` and silently retired
    ///   production's embedding binding; the daemon accepts it without
    ///   complaint (desktop-assistant#647);
    /// * `interactive` claims to inherit — there is no primary above it;
    /// * the result equals `lastKnown`, the binding the daemon last reported.
    ///   This is the rule that makes reconciliation incapable of writing: a
    ///   reconcile sets the row to exactly that state, so anything it triggers
    ///   is a no-op regardless of when the notification arrives.
    public static func planned(
        purpose: String,
        selection: PurposeSelection,
        lastKnown: PurposeConfigView?
    ) -> PurposeConfigView? {
        guard AdeleCore.purposeKinds.contains(purpose) else { return nil }
        guard let connection = realValue(selection.connection),
              let model = realValue(selection.model) else { return nil }

        let connectionInherits = connection == primarySentinel
        let modelInherits = model == primarySentinel
        guard connectionInherits == modelInherits else { return nil }
        if connectionInherits && purpose == "interactive" { return nil }

        let candidate = PurposeConfigView(
            connection: connection,
            model: model,
            effort: selection.effort,
            maxContextTokens: selection.maxContextTokens
        )
        if candidate == lastKnown { return nil }
        return candidate
    }

    /// A dropdown value only counts as a selection when it is a non-blank
    /// string; a partially-loaded list can leave a placeholder behind.
    private static func realValue(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespaces),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// How a row should render the daemon's reported binding.
    ///
    /// The counterpart to the write rules: a binding this client refuses to
    /// emit must not be shown as though it were an ordinary model either. In
    /// production the embedding row read `connection = "bedrock"` with
    /// `model = "primary"` and displayed the bare word "primary", which looked
    /// like a model name and hid the fault for as long as it took to notice
    /// nothing was being embedded.
    public static func displayLabel(for config: PurposeConfigView?) -> String {
        guard let config else { return "Default" }
        let connectionInherits = config.connection == primarySentinel
        let modelInherits = config.model == primarySentinel
        if connectionInherits && modelInherits { return "Inherit from Interactive" }
        if connectionInherits != modelInherits { return "Invalid — reselect" }
        return config.model
    }
}
