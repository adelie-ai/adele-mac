import Foundation

/// The local "Share device info with the assistant" opt-out (#549).
///
/// The daemon folds per-turn client context — device name, username, home
/// folder, hostname, time zone, OS — into the system prompt so the assistant can
/// personalize, and reports the *client* host in `sys_props`. This is the
/// client-side opt-out: a purely local preference (no daemon round-trip), stored
/// in `UserDefaults` alongside the voice settings, and pushed to the Rust core
/// via `AdeleCore.setShareClientContext`, which stages it for the next connect.
///
/// **The default is ON**, matching `ConnectionConfig::default().share_client_context`.
/// That is why the getter probes for the key's presence instead of calling
/// `UserDefaults.bool(forKey:)`, which reports `false` for an absent key — the
/// exact opposite of the intended default.
public struct ClientContextPreference {
    /// The `UserDefaults` key holding the user's explicit choice. Absent until
    /// the user touches the toggle.
    public static let defaultsKey = "shareClientContext"

    /// The value used when the user has never chosen — ON, mirroring the core's
    /// `ConnectionConfig` default.
    public static let defaultValue = true

    private let defaults: UserDefaults

    /// `defaults` is injectable so tests exercise a throwaway suite rather than
    /// the app's real domain.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isEnabled: Bool {
        get {
            guard defaults.object(forKey: Self.defaultsKey) != nil else {
                return Self.defaultValue
            }
            return defaults.bool(forKey: Self.defaultsKey)
        }
        nonmutating set {
            defaults.set(newValue, forKey: Self.defaultsKey)
        }
    }
}
