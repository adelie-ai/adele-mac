#!/usr/bin/env bash
# Build and launch adele-mac as a proper .app bundle.
#
# A bare `swift run` executable launches as a non-activating process, so its
# window can't take keyboard focus (focus stays on the terminal). Wrapping the
# binary in a minimal .app bundle with an Info.plist makes LaunchServices treat
# it as a real app — it activates and takes focus normally.
#
# The binary keeps its absolute dev RPATH to the Rust core's cargo target dir, so
# the co-located dylib resolves without embedding it in the bundle (dev only; a
# distributable bundle embeds it — a later phase).
set -euo pipefail

CONFIG="${1:-debug}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$MAC_DIR"

SWIFT_FLAGS=(--product AdeleMac)
[[ "$CONFIG" == "release" ]] && SWIFT_FLAGS+=(-c release)

"$SCRIPT_DIR/build-core.sh" "$CONFIG"
swift build "${SWIFT_FLAGS[@]}"

BIN="$MAC_DIR/.build/$CONFIG/AdeleMac"
APP="$MAC_DIR/.build/AdeleMac.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/AdeleMac"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Adele</string>
    <key>CFBundleDisplayName</key><string>Adele</string>
    <key>CFBundleIdentifier</key><string>tech.spadea.adele-mac</string>
    <key>CFBundleExecutable</key><string>AdeleMac</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key><string>Adele uses the microphone for voice dictation.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>Adele transcribes your dictation to text with on-device speech recognition.</string>
</dict>
</plist>
PLIST

echo ">> launching $APP"
open "$APP"
