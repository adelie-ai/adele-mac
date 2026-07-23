import Foundation

/// Presentation metadata for a transcript message — the Swift mirror of
/// api-model's `client::MessageKind` (voice#126). Explicit metadata so a UI never
/// has to parse a message's text to know what a bubble is: daemon-sourced
/// messages are always `.normal`, and clients tag the lines they generate
/// locally for the `say_this` voice tool.
public enum MessageKind: String, Decodable, Hashable, Sendable, CaseIterable {
    /// An ordinary user / assistant / system / tool message.
    case normal
    /// A line Adele spoke aloud via the `say_this` voice tool (on-demand mode).
    /// A real transcript entry, badged "Spoken".
    case spoken
    /// A `say_this` the client did not speak because voice output is off — shown
    /// but not voiced.
    case speechDisabled = "speech_disabled"

    /// Decode from the wire spelling, tolerating both the field's absence and a
    /// value this build doesn't know.
    ///
    /// Absence is not an edge case: older daemons predate `MessageKind`
    /// entirely, and an older core omits it from the view-events — so `nil` must
    /// mean `.normal`, never a decode failure that would sink the whole
    /// transcript or drop a note. Spelling is normalized (case- and
    /// underscore-insensitive) because serde's default is PascalCase (`Spoken`)
    /// while the view-event tags are renamed to snake_case; accepting both keeps
    /// this working whichever way the DTO ends up serialized.
    public init(wire: String?) {
        guard let wire else {
            self = .normal
            return
        }
        switch wire.lowercased().replacingOccurrences(of: "_", with: "") {
        case "spoken": self = .spoken
        case "speechdisabled": self = .speechDisabled
        default: self = .normal
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(wire: try? container.decode(String.self))
    }

    /// The short marker shown beside a client-tagged transcript line, or `nil`
    /// for `.normal` (an ordinary message is never badged). The analog of
    /// adele-gtk's `kind_marker`.
    public var badgeLabel: String? {
        switch self {
        case .normal: return nil
        case .spoken: return "Spoken"
        case .speechDisabled: return "Speech off"
        }
    }

    /// The screen-reader form of `badgeLabel` — the badge is a glyph plus two
    /// words, which doesn't stand on its own out of context.
    public var accessibilityDescription: String? {
        switch self {
        case .normal: return nil
        case .spoken: return "Adele spoke this aloud"
        case .speechDisabled: return "Shown but not spoken — voice output is off"
        }
    }

}
