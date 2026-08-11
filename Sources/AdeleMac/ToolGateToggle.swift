import AdeleCore
import SwiftUI

/// The per-conversation tool-provenance-gate control (desktop-assistant#1007).
///
/// Modelled on the Scratchpad toggle rather than the Personality sheet: one
/// boolean with nothing to pre-fill, so a direct control fits better than a
/// dialog. It reads its state without any menu being opened, because "what is
/// this conversation allowed to do" is not a thing a person should have to go
/// looking for.
///
/// The wording says what the setting does to the assistant's behaviour, not what
/// threat it counters.
struct ToolGateToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.setToolGateDisabled(!model.toolGateDisabled)
        } label: {
            Label(label, systemImage: symbol)
                // The non-default state must look non-default. A gate that is
                // off stays visible as off at a glance, without being read.
                .foregroundStyle(model.toolGateDisabled ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
        }
        .help(help)
    }

    private var label: String {
        model.toolGateDisabled ? "Tools unrestricted" : "Tools checked"
    }

    private var symbol: String {
        model.toolGateDisabled ? "lock.open" : "lock"
    }

    private var help: String {
        model.toolGateDisabled
            ? "This conversation acts on what it reads. Click to check tool use again."
            : "This conversation refuses to act after reading outside content. Click to allow it."
    }
}
