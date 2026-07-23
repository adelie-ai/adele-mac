import Testing
import Foundation
@testable import AdeleCore

/// Spec: the local "Share device info with the assistant" opt-out (#549) is ON
/// unless the user turned it off, matching `ConnectionConfig::default()`, and it
/// survives a relaunch.
@Suite struct ClientContextPreferenceTests {
    /// A throwaway `UserDefaults` suite so a test never reads or writes the real
    /// app domain.
    private func withFreshDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "adele-mac.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("could not open a test UserDefaults suite"); return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    // The acceptance criterion: nothing persisted ⇒ sharing is ON. Note this
    // cannot lean on `UserDefaults.bool(forKey:)`, which reports `false` for an
    // absent key — exactly the wrong default here.
    @Test func defaultsToOnWhenNothingIsPersisted() {
        withFreshDefaults { defaults in
            #expect(ClientContextPreference(defaults: defaults).isEnabled)
        }
    }

    @Test func defaultValueMatchesTheCoreConnectionConfig() {
        #expect(ClientContextPreference.defaultValue == true)
    }

    @Test func optingOutPersists() {
        withFreshDefaults { defaults in
            let prefs = ClientContextPreference(defaults: defaults)
            prefs.isEnabled = false
            #expect(!prefs.isEnabled)
            // A fresh instance over the same store (i.e. the next launch) agrees.
            #expect(!ClientContextPreference(defaults: defaults).isEnabled)
        }
    }

    @Test func optingBackInPersists() {
        withFreshDefaults { defaults in
            let prefs = ClientContextPreference(defaults: defaults)
            prefs.isEnabled = false
            prefs.isEnabled = true
            #expect(ClientContextPreference(defaults: defaults).isEnabled)
        }
    }

    @Test func readsAnExplicitlyStoredValue() {
        withFreshDefaults { defaults in
            defaults.set(false, forKey: ClientContextPreference.defaultsKey)
            #expect(!ClientContextPreference(defaults: defaults).isEnabled)
            defaults.set(true, forKey: ClientContextPreference.defaultsKey)
            #expect(ClientContextPreference(defaults: defaults).isEnabled)
        }
    }
}
