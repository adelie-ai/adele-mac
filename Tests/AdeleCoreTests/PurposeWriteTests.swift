import Testing
import Foundation
@testable import AdeleCore

/// Spec for `PurposeWrite.planned` — the pure decision "is this purposes-row
/// state a write worth sending?". The Swift port of GTK's `planned_write`
/// (adele-gtk#142 / PR #143), which took `adele-prod` down twice in one day.
///
/// Two rules, both expressed as data rather than as signal timing:
///
///  1. Never emit a binding the UI could not display. A row whose model list
///     did not load has nothing real selected, and a mixed `"primary"` pair
///     (a real connection with the inherit sentinel as its model, or the
///     reverse) is the exact shape that silently retired production's
///     embedding binding.
///  2. Drop any write whose result equals the daemon's last reported binding.
///     Reconciliation sets the UI to exactly that state, so a reconcile becomes
///     structurally incapable of writing — no suppression flag, no dependence
///     on when a change notification is delivered.
@Suite struct PurposeWriteTests {
    // MARK: Fixtures

    private func sel(
        _ connection: String?,
        _ model: String?,
        effort: String? = nil,
        maxContextTokens: UInt64? = nil
    ) -> PurposeSelection {
        PurposeSelection(
            connection: connection,
            model: model,
            effort: effort,
            maxContextTokens: maxContextTokens
        )
    }

    private func cfg(
        _ connection: String,
        _ model: String,
        effort: String? = nil,
        maxContextTokens: UInt64? = nil
    ) -> PurposeConfigView {
        PurposeConfigView(
            connection: connection,
            model: model,
            effort: effort,
            maxContextTokens: maxContextTokens
        )
    }

    // MARK: Hazard 2 — reconciliation that writes

    /// `reconciling_to_server_state_is_not_a_write`.
    ///
    /// The GTK loop was: write succeeds -> refresh -> reconcile -> a change
    /// notification fires -> another write, at ~3 writes/sec. Reconcile sets the
    /// row to exactly `lastKnown`, so the write it would produce is a no-op and
    /// must be dropped.
    @Test func reconcilingToServerStateIsNotAWrite() {
        let server = cfg("bedrock", "zai.glm-5")
        #expect(PurposeWrite.planned(
            purpose: "embedding",
            selection: sel("bedrock", "zai.glm-5"),
            lastKnown: server
        ) == nil)
    }

    /// The no-op check compares the whole binding, not just connection+model:
    /// a row reconciled to a server state that carries effort and a context
    /// override is still not a write.
    @Test func reconcilingToAFullServerStateIsNotAWrite() {
        let server = cfg("bedrock", "zai.glm-5", effort: "high", maxContextTokens: 8192)
        #expect(PurposeWrite.planned(
            purpose: "titling",
            selection: sel("bedrock", "zai.glm-5", effort: "high", maxContextTokens: 8192),
            lastKnown: server
        ) == nil)
    }

    // MARK: Hazard 1 — a mixed `primary` pair / an undisplayable binding

    /// `unavailable_model_list_is_not_writable`.
    ///
    /// The connection's `ListModels` failed, so the row's model dropdown holds
    /// nothing real. The row must not be writable at all.
    @Test func unavailableModelListIsNotWritable() {
        #expect(PurposeWrite.planned(
            purpose: "embedding",
            selection: sel("bedrock", nil),
            lastKnown: nil
        ) == nil)
    }

    @Test func unavailableConnectionListIsNotWritable() {
        #expect(PurposeWrite.planned(
            purpose: "embedding",
            selection: sel(nil, "nomic-embed-text"),
            lastKnown: nil
        ) == nil)
    }

    /// A partially-loaded list can leave a placeholder empty string selected.
    /// Blank is "nothing real selected", not a value worth writing.
    @Test func blankSelectionIsNotWritable() {
        #expect(PurposeWrite.planned(
            purpose: "embedding",
            selection: sel("", "nomic-embed-text"),
            lastKnown: nil
        ) == nil)
        #expect(PurposeWrite.planned(
            purpose: "embedding",
            selection: sel("bedrock", "   "),
            lastKnown: nil
        ) == nil)
    }

    /// `mixed_primary_pair_is_never_emitted` — the exact shape that shipped to
    /// production: a real connection id with the inherit sentinel as the model.
    /// The daemon accepts it silently and embeddings resolve to a
    /// text-generation model.
    @Test func mixedPrimaryPairIsNeverEmitted() {
        #expect(PurposeWrite.planned(
            purpose: "embedding",
            selection: sel("bedrock", PurposeWrite.primarySentinel),
            lastKnown: cfg("default", "nomic-embed-text")
        ) == nil)
    }

    /// …and in the other direction.
    @Test func mixedPrimaryPairIsNeverEmittedInEitherOrder() {
        #expect(PurposeWrite.planned(
            purpose: "embedding",
            selection: sel(PurposeWrite.primarySentinel, "zai.glm-5"),
            lastKnown: nil
        ) == nil)
    }

    /// `interactive_cannot_inherit` — there is no primary above interactive to
    /// inherit from.
    @Test func interactiveCannotInherit() {
        #expect(PurposeWrite.planned(
            purpose: "interactive",
            selection: sel(PurposeWrite.primarySentinel, PurposeWrite.primarySentinel),
            lastKnown: nil
        ) == nil)
    }

    /// The guard is not a substitute for knowing the purpose: a kind the daemon
    /// does not define is never emitted.
    @Test func unknownPurposeIsNotWritable() {
        #expect(PurposeWrite.planned(
            purpose: "summarising",
            selection: sel("bedrock", "zai.glm-5"),
            lastKnown: nil
        ) == nil)
    }

    @Test func everyDaemonPurposeKindIsWritable() {
        for kind in AdeleCore.purposeKinds {
            #expect(PurposeWrite.planned(
                purpose: kind,
                selection: sel("bedrock", "zai.glm-5"),
                lastKnown: nil
            ) == cfg("bedrock", "zai.glm-5"), "\(kind) must be writable")
        }
    }

    // MARK: The guard must not break editing

    /// `a_genuine_change_is_still_a_write`.
    @Test func aGenuineChangeIsStillAWrite() {
        #expect(PurposeWrite.planned(
            purpose: "embedding",
            selection: sel("default", "nomic-embed-text"),
            lastKnown: cfg("bedrock", "zai.glm-5")
        ) == cfg("default", "nomic-embed-text"))
    }

    /// A deliberate inherit pair — both sides `"primary"` — is a real choice on
    /// any purpose except interactive.
    @Test func aDeliberateInheritPairIsAWrite() {
        #expect(PurposeWrite.planned(
            purpose: "dreaming",
            selection: sel(PurposeWrite.primarySentinel, PurposeWrite.primarySentinel),
            lastKnown: cfg("bedrock", "zai.glm-5")
        ) == cfg(PurposeWrite.primarySentinel, PurposeWrite.primarySentinel))
    }

    @Test func anEffortOnlyChangeIsAWrite() throws {
        let written = try #require(PurposeWrite.planned(
            purpose: "titling",
            selection: sel("bedrock", "zai.glm-5", effort: "high"),
            lastKnown: cfg("bedrock", "zai.glm-5")
        ), "changing only the effort is still a real change")
        #expect(written.effort == "high")
    }

    /// A purpose the daemon has never reported can still be set for the first
    /// time — an absent `lastKnown` is not "equal to the server state".
    @Test func firstWriteWithNoKnownServerStateIsAllowed() {
        #expect(PurposeWrite.planned(
            purpose: "voice",
            selection: sel("bedrock", "zai.glm-5"),
            lastKnown: nil
        ) == cfg("bedrock", "zai.glm-5"))
    }

    // MARK: `SetPurpose` is a full replace

    /// `a_context_window_override_is_preserved`. The macOS UI does not edit the
    /// per-purpose context-window override (desktop-assistant#51), but
    /// `SetPurpose` replaces the whole config — so an override set from the TUI
    /// or config file must survive a menu pick here.
    @Test func aContextWindowOverrideIsPreserved() throws {
        let written = try #require(PurposeWrite.planned(
            purpose: "embedding",
            selection: sel("default", "nomic-embed-text", maxContextTokens: 8192),
            lastKnown: cfg("bedrock", "zai.glm-5", maxContextTokens: 8192)
        ), "a real change")
        #expect(written.maxContextTokens == 8192)
    }

    /// The same argument for effort: it is carried, not silently cleared.
    @Test func anEffortSetElsewhereIsPreserved() throws {
        let written = try #require(PurposeWrite.planned(
            purpose: "dreaming",
            selection: sel("default", "nomic-embed-text", effort: "low"),
            lastKnown: cfg("bedrock", "zai.glm-5", effort: "low")
        ), "a real change")
        #expect(written.effort == "low")
    }

    // MARK: Carrying the un-edited fields off the last reported binding

    /// The convenience the UI actually calls: a menu pick supplies only
    /// connection+model, and the fields it does not edit come off the daemon's
    /// last reported binding.
    @Test func selectionFromServerStateCarriesUneditedFields() {
        let server = cfg("bedrock", "zai.glm-5", effort: "high", maxContextTokens: 8192)
        let selection = PurposeSelection(
            pick: (connection: "default", model: "nomic-embed-text"),
            carryingFrom: server
        )
        #expect(selection.effort == "high")
        #expect(selection.maxContextTokens == 8192)
    }

    @Test func selectionFromNoServerStateCarriesNothing() {
        let selection = PurposeSelection(
            pick: (connection: "default", model: "nomic-embed-text"),
            carryingFrom: nil
        )
        #expect(selection.effort == nil)
        #expect(selection.maxContextTokens == nil)
    }

    /// End to end through the convenience: re-picking the model the daemon
    /// already reports is still not a write, even with un-edited fields set.
    @Test func repickingTheCurrentModelIsNotAWrite() {
        let server = cfg("bedrock", "zai.glm-5", effort: "high", maxContextTokens: 8192)
        #expect(PurposeWrite.planned(
            purpose: "titling",
            selection: PurposeSelection(
                pick: (connection: "bedrock", model: "zai.glm-5"),
                carryingFrom: server
            ),
            lastKnown: server
        ) == nil)
    }

    // MARK: Displaying a binding honestly

    @Test func anUnsetPurposeReadsAsDefault() {
        #expect(PurposeWrite.displayLabel(for: nil) == "Default")
    }

    @Test func anInheritPairIsNotShownAsAModelNamed_primary() {
        #expect(PurposeWrite.displayLabel(
            for: cfg(PurposeWrite.primarySentinel, PurposeWrite.primarySentinel)
        ) == "Inherit from Interactive")
    }

    /// Production's broken embedding row rendered the bare word "primary",
    /// which read as a model name. A mixed pair must announce itself.
    @Test func aMixedPrimaryPairIsShownAsInvalid() {
        #expect(PurposeWrite.displayLabel(
            for: cfg("bedrock", PurposeWrite.primarySentinel)
        ) == "Invalid — reselect")
        #expect(PurposeWrite.displayLabel(
            for: cfg(PurposeWrite.primarySentinel, "zai.glm-5")
        ) == "Invalid — reselect")
    }

    @Test func anOrdinaryBindingReadsAsItsModel() {
        #expect(PurposeWrite.displayLabel(for: cfg("bedrock", "zai.glm-5")) == "zai.glm-5")
    }
}
