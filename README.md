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

## Status

Validated end-to-end against a live `desktop-assistant-daemon` (streamed replies,
model listing, voice) via `AdeleSmoke`.

**Done**
- **Phase 1** — FFI integration, `AdeleCore` wrapper, `/login`→JWT auth, WS
  connect, streaming chat, conversation sidebar (new/select/delete), send gating.
- **Phase 2** — native Markdown rendering, model picker (+ reasoning effort),
  context-usage readout, background tasks panel (list/progress/cancel/logs),
  scratchpad inspector, toasts + inline notes.
- **Phase 3 (partial)** — connection profiles + macOS Keychain + auto-reconnect +
  in-app profile switching.
- **Voice** — output via `AVSpeechSynthesizer` (per-conversation level + a Voice
  settings tab: voice picker, rate/pitch); **input** via `SFSpeechRecognizer`
  dictation (mic button in the composer).
- **Settings (⌘,)** — model **purposes**, **connections editor**
  (create/update/delete anthropic/openai/bedrock/ollama, with **direct credential
  entry** and edit pre-fill), **MCP servers**, **personality** (7 dials); plus a
  **knowledge base** browser/editor. All over a generic FFI management bridge
  (`adele_core_send_command`).
- **Conversations** — new/select/delete, **rename**, **archive/unarchive**
  (archived grouped in their own section), **per-conversation personality**.
- **Chat** — native Markdown, model picker (+ effort + **select-models filter**),
  context-usage meter, tasks panel, scratchpad, toasts, avatars.
- **UX** — Return-to-send, delete confirmation, Cmd-N / Cmd-Opt-S shortcuts.

Covered by a **Swift Testing** suite — run `./scripts/test.sh`. Build a
self-contained (unsigned) `.app` with `./scripts/build-app.sh`.

**Remaining toward GTK parity**
- First-run setup wizard; multi-window (needs a per-window connection/core).
- OAuth login flow (the password `/login` path works; OAuth needs an
  OAuth-configured daemon to build against).
- Distribution: **signing + notarization** (needs an Apple Developer ID) and a
  Homebrew cask; a universal (arm64+x86_64) build. `build-app.sh` produces the
  unsigned bundle today.

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
