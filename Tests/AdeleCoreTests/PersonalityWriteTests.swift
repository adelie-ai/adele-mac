import Testing
import Foundation
@testable import AdeleCore

/// Spec for `PersonalityWrite.planned` — the pure decision "is this personality
/// dial a write worth sending?". The personality sibling of `PurposeWrite`
/// (issue #13), ported from the same GTK write-loop rule (adele-gtk#142 /
/// PR #143) that took `adele-prod` down twice in one day.
///
/// The personality editor (`PersonalitySettingsView`) writes each dial from a
/// two-way `Picker(selection:)` binding whose setter calls `setPersonality` —
/// UI mutation and write are the same event, structurally the GTK shape. The
/// durable, framework-independent guard is the same one #10 landed for
/// purposes: **drop any write whose result equals the daemon's last reported
/// value.** A reconcile then sets the dial to exactly that value and is
/// structurally incapable of writing — no suppression flag, no dependence on
/// when a change notification is delivered.
@Suite struct PersonalityWriteTests {
    // MARK: Hazard — reconciliation that writes

    /// `reconciling_personality_to_server_state_is_not_a_write` (acceptance).
    ///
    /// A reconcile sets the dial to exactly `lastKnown`. The write it would
    /// produce is a no-op and must be dropped, so the loop is structurally
    /// impossible independent of notification timing.
    @Test func reconcilingPersonalityToServerStateIsNotAWrite() {
        #expect(PersonalityWrite.planned(
            trait: "warmth",
            desired: "often",
            lastKnown: "often"
        ) == nil)
    }

    /// `personality_write_survives_a_refresh_without_re_emitting` (acceptance).
    ///
    /// After a dial is written (server now reports the new level), a post-write
    /// refresh reloads that same level. Were the refresh to feed back through
    /// the binding setter, `desired == lastKnown` drops it — no second write.
    @Test func personalityWriteSurvivesARefreshWithoutReEmitting() {
        // The write: user moved warmth from "sometimes" to "often".
        #expect(PersonalityWrite.planned(
            trait: "warmth",
            desired: "often",
            lastKnown: "sometimes"
        ) == "often")
        // The daemon now reports "often"; a refresh-driven re-emit is a no-op.
        #expect(PersonalityWrite.planned(
            trait: "warmth",
            desired: "often",
            lastKnown: "often"
        ) == nil)
    }

    /// The no-op rule holds for every one of the 7 dials — none is special.
    @Test func reconcilingIsNotAWriteForEveryDial() {
        for trait in Personality.traitNames {
            #expect(PersonalityWrite.planned(
                trait: trait,
                desired: "always",
                lastKnown: "always"
            ) == nil, "\(trait) reconcile must be a no-op")
        }
    }

    // MARK: A genuine edit is still a write

    /// The guard must not break editing: a real level change is emitted.
    @Test func aGenuineChangeIsStillAWrite() {
        #expect(PersonalityWrite.planned(
            trait: "humor",
            desired: "always",
            lastKnown: "never"
        ) == "always")
    }

    /// Every dial is writable — the guard is not a trait allow/deny list.
    @Test func everyDialIsWritable() {
        for trait in Personality.traitNames {
            #expect(PersonalityWrite.planned(
                trait: trait,
                desired: "often",
                lastKnown: "sometimes"
            ) == "often", "\(trait) must be writable")
        }
    }

    /// A change across each adjacent level pair is a write (no accidental
    /// equality from case or spacing).
    @Test func everyLevelTransitionIsAWrite() {
        let levels = Personality.levels
        for i in levels.indices.dropLast() {
            #expect(PersonalityWrite.planned(
                trait: "directness",
                desired: levels[i + 1],
                lastKnown: levels[i]
            ) == levels[i + 1])
        }
    }

    // MARK: Unhappy paths

    /// A dial the daemon has never reported (all-nil `Personality` because the
    /// daemon omitted the block, or a partially-loaded personality) can still be
    /// set for the first time — an absent `lastKnown` is not "equal to server".
    @Test func firstWriteWithNoKnownServerValueIsAllowed() {
        #expect(PersonalityWrite.planned(
            trait: "sarcasm",
            desired: "rarely",
            lastKnown: nil
        ) == "rarely")
    }

    /// A partially-loaded personality: some dials have a server value, others do
    /// not. The unloaded ones are first writes; the loaded ones still honor the
    /// no-op rule.
    @Test func partiallyLoadedPersonalityDialsAreHandledPerDial() {
        // Loaded dial reconciling → no-op.
        #expect(PersonalityWrite.planned(
            trait: "professionalism",
            desired: "often",
            lastKnown: "often"
        ) == nil)
        // Unloaded sibling dial → first write allowed.
        #expect(PersonalityWrite.planned(
            trait: "enthusiasm",
            desired: "often",
            lastKnown: nil
        ) == "often")
    }

    /// A blank or whitespace desired value means the picker has nothing real
    /// selected (a partially-loaded control). Never a write.
    @Test func blankDesiredIsNotWritable() {
        #expect(PersonalityWrite.planned(
            trait: "warmth", desired: nil, lastKnown: "often") == nil)
        #expect(PersonalityWrite.planned(
            trait: "warmth", desired: "", lastKnown: "often") == nil)
        #expect(PersonalityWrite.planned(
            trait: "warmth", desired: "   ", lastKnown: nil) == nil)
    }

    /// The guard is not a substitute for knowing the trait: a name the daemon
    /// does not define is never emitted.
    @Test func unknownTraitIsNotWritable() {
        #expect(PersonalityWrite.planned(
            trait: "grumpiness",
            desired: "always",
            lastKnown: nil
        ) == nil)
    }

    /// Whitespace around an otherwise-equal value must not defeat the no-op
    /// rule — a padded desired that trims to `lastKnown` is still a reconcile.
    @Test func whitespacePaddedReconcileIsStillANoOp() {
        #expect(PersonalityWrite.planned(
            trait: "pretentiousness",
            desired: "  sometimes  ",
            lastKnown: "sometimes"
        ) == nil)
    }
}
