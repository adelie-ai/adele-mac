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
    /// A real transcript entry, rendered with a "Spoken" marker.
    case spoken
    /// A `say_this` the client did not speak because voice output is off — shown
    /// but not voiced.
    case speechDisabled = "speech_disabled"

    /// Decode from the wire spelling, tolerating both the field's absence and a
    /// value this build doesn't know.
    ///
    /// Absence is the common case, not an edge case: older daemons predate
    /// `MessageKind` entirely, and today's FFI `ChatMessageDto` doesn't project
    /// it either — so `nil` must mean `.normal`, never a decode failure that
    /// would sink the whole transcript. Spelling is normalized (case- and
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

    /// Recover the kind from an `inline_note` view-event's text.
    ///
    /// Interim bridge. The FFI boundary has no `kind` field on `inline_note`: it
    /// stringifies the metadata into the text instead (client-ui-ffi's
    /// `view_event.rs`, the KDE-era interim presentation). Splitting the marker
    /// back off here confines the string-matching to one tested function and lets
    /// the transcript render a real badge; when the FFI projects `kind` properly
    /// this collapses to reading the field, and the markers below go away.
    public static func fromInlineNote(_ text: String) -> (kind: MessageKind, content: String) {
        if text.hasPrefix(spokenMarker) {
            return (.spoken, String(text.dropFirst(spokenMarker.count)))
        }
        if text.hasPrefix(speechDisabledMarker) {
            return (.speechDisabled, String(text.dropFirst(speechDisabledMarker.count)))
        }
        return (.normal, text)
    }

    private static let spokenMarker = "Spoken: "
    private static let speechDisabledMarker = "(speech mode disabled) "
}
