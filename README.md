# Adele Mac

Native macOS (SwiftUI) client for the [Adelie AI Platform](https://github.com/adelie-ai/desktop-assistant).

Like `adele-kde`, this is **glue over the shared Rust core**: it links
`libadele_client_core` (built from `client-ui-common/ffi`), which owns the
`client-ui-common` reducer — the same `WindowState` state machine the GTK, TUI,
and KDE clients run — plus a `client-common` transport. All model, controller,
and transport logic lives in Rust; the Swift side forwards user intents and
renders the core's pushed view-events. The daemon connection uses **WebSocket**
(macOS has no D-Bus).

## Layout

| Target | Role |
|--------|------|
| `CAdeleCore` | System-library module wrapping the cbindgen-generated C ABI header. |
| `AdeleCore` | Swift wrapper over the C ABI — owns the `Core` handle, marshals JSON view-events onto the main actor, decodes them to typed `ViewEvent`s, exposes typed intents. Analog of adele-kde's `AdeleCore` QObject. |
| `AdeleMac` | The SwiftUI app: `NavigationSplitView` sidebar + chat pane, folds `ViewEvent`s into observable state. |

## Requirements

- macOS 14+
- Swift 6 toolchain (Xcode or Command Line Tools)
- Rust toolchain (`cargo`) — builds the native core
- The `client-ui-common`, `desktop-assistant`, and `voice` checkouts as siblings
  of this directory (standard adelie-ai layout)
- A running `desktop-assistant-daemon` reachable over WebSocket

## Build & run

```sh
# 1. Build the Rust core (libadele_client_core) and stage its C header.
./scripts/build-core.sh            # or: ./scripts/build-core.sh release

# 2. Build + run the app.
swift build
swift run AdeleMac
```

The app opens a connect screen; enter the daemon's WebSocket URL
(default `ws://127.0.0.1:11339/ws`) and connect.

## Status — Phase 1 (walking skeleton) ✅ validated end-to-end

Implemented: FFI build integration, `AdeleCore` wrapper, `/login`→JWT auth,
WebSocket connect, streaming chat (plain text), conversation sidebar (new /
select / delete), chat status + send gating. Verified against a live
`desktop-assistant-daemon` (streamed a real assistant reply via `AdeleSmoke`).

### Auth (macOS)

macOS has no D-Bus token minter, so the client fetches a bearer token from the
daemon's `/login` (HTTP basic-auth, derived from the ws URL) via `WSLogin`, then
stages it with `AdeleCore.setWSJWT` before connecting. This required an additive
FFI function `adele_core_set_ws_jwt` (in `client-ui-common/ffi`) — non-breaking
for the KDE/D-Bus path, and a real portability improvement to upstream.

### Headless smoke test

```sh
ADELE_WS_URL=ws://127.0.0.1:11339/ws \
ADELE_WS_USER=adele ADELE_WS_PASS=… \
swift run AdeleSmoke
```

Logs each view-event; exits 0 once it streams a `complete`.

Not yet: native markdown, model picker, tasks panel, context-usage UI,
scratchpad, connection profiles / OAuth / Keychain, voice, settings. See the
project plan for the full phased roadmap toward GTK parity.

### Notes

- Phase 1 links the debug **dylib** directly with a dev RPATH (the same approach
  adele-kde uses for its cdylib). A universal static lib + `.app` bundle
  (codesign/notarize) is a later phase.
- The core builds with default features (D-Bus transport compiled in but unused
  on macOS — we always connect over WS). Gating D-Bus off for the Mac build is a
  later cleanup.
