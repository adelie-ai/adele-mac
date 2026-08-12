import SwiftUI

/// The app's transient toast, drawn over the top of whatever it is applied to.
///
/// Every scene that can start a write carries this. The core reports a refused
/// write - a client MCP config it cannot parse, a name it will not take - as a
/// `toast` view event with no other trace, so a scene without a toast surface
/// shows nothing at all when the core declines (adele-mac#35). The Settings
/// window administers MCP servers, connections and personalities, so it needs
/// the same surface the main window has.
///
/// Requires `AppModel` in the environment. Apply it *inside* whatever supplies
/// that value, so the overlay reads the same model the content does.
private struct ToastOverlay: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let toast = model.toast {
                    Text(toast)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.separator))
                        .shadow(radius: 8, y: 4)
                        .padding(.top, 12)
                        .frame(maxWidth: 420)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.3), value: model.toast)
    }
}

extension View {
    /// Show the app's toasts over this view.
    func adeleToasts() -> some View {
        modifier(ToastOverlay())
    }
}
