import Foundation

/// Whether a personality-dial change is a write worth sending.
///
/// The personality sibling of `PurposeWrite` (issue #13). The personality
/// editor writes each of the "Expressive 7" dials from a two-way
/// `Picker(selection:)` binding whose setter calls `setPersonality` — so the UI
/// mutation and the write are the same event, structurally the shape of GTK's
/// `planned_write` loop (adele-gtk#142 / PR #143) that took `adele-prod` down
/// twice in one day. Anything that sets a dial from server state (a reconcile, a
/// post-write refresh, a reconnect) can therefore emit another write.
///
/// Like `PurposeWrite`, this is a pure function on purpose. GTK's earlier
/// attempt suppressed writes with a boolean flag held across its reconcile,
/// which only covered notifications delivered synchronously; anything arriving
/// after the reconcile returned found the flag cleared and re-emitted. Deciding
/// from data — the candidate level versus the daemon's last reported level —
/// rather than from signal timing is what makes the loop structurally
/// impossible, and what makes the rule testable without a daemon or a UI.
public enum PersonalityWrite {
    /// Returns the level to send for `trait`, or `nil` for "not a user-intended
    /// change, send nothing".
    ///
    /// `nil` is returned when:
    ///
    /// * `trait` is not one of `Personality.traitNames` — never invent a write
    ///   for a dial the daemon does not define;
    /// * `desired` has no real value (nil, blank, or whitespace), because a
    ///   partially-loaded picker cannot honestly represent a level;
    /// * the (trimmed) `desired` equals `lastKnown`, the level the daemon last
    ///   reported. This is the rule that makes reconciliation incapable of
    ///   writing: a reconcile sets the dial to exactly that level, so anything
    ///   it triggers is a no-op regardless of when the notification arrives.
    ///
    /// A `nil` `lastKnown` (a dial the daemon never reported, or a
    /// partially-loaded personality) is not "equal to the server value", so a
    /// genuine first write is still allowed.
    public static func planned(
        trait: String,
        desired: String?,
        lastKnown: String?
    ) -> String? {
        guard Personality.traitNames.contains(trait) else { return nil }
        guard let candidate = realValue(desired) else { return nil }
        if candidate == lastKnown { return nil }
        return candidate
    }

    /// A dial value only counts as a selection when it is a non-blank string; a
    /// partially-loaded picker can leave a placeholder behind. Trimming also
    /// keeps a padded value from defeating the no-op rule.
    private static func realValue(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespaces),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
