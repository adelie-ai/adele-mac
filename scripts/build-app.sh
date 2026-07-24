#!/usr/bin/env bash
# Build a self-contained (unsigned) release .app bundle of adele-mac.
#
# Unlike run-app.sh (dev, links the debug dylib by an absolute RPATH), this
# bundles the Rust core dylib inside the app (Contents/Frameworks) with an
# @executable_path RPATH, so the .app runs on another machine without the cargo
# target dir. It is UNSIGNED: Gatekeeper warns on first open — right-click → Open,
# or `xattr -dr com.apple.quarantine <app>`. Codesigning + notarization
# (Developer ID) is a later step. Universal (arm64 + x86_64) requires building
# each arch and `lipo`-ing the dylib + binary; this builds the host arch.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$MAC_DIR"

CORE_DIR="${ADELE_CORE_DIR:-$(cd "$MAC_DIR/.." && pwd)/client-ui-common}"
CORE_LIB="$CORE_DIR/target/release/libadele_client_core.dylib"

echo ">> building Rust core (release)"
( cd "$CORE_DIR" && cargo build --release -p client-ui-ffi )
mkdir -p Sources/CAdeleCore/include
cp "$CORE_DIR/ffi/include/adele_client_core.h" Sources/CAdeleCore/include/

echo ">> building AdeleMac (release)"
ADELE_CORE_LIB_DIR="$CORE_DIR/target/release" swift build -c release --product AdeleMac

BIN="$MAC_DIR/.build/release/AdeleMac"
APP="$MAC_DIR/.build/AdeleMac.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AdeleMac"
cp "$CORE_LIB" "$APP/Contents/Frameworks/libadele_client_core.dylib"
cp "$MAC_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# The dylib's install_name is @rpath/libadele_client_core.dylib; add an
# @executable_path RPATH so the bundled copy resolves at runtime.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/AdeleMac" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Adele</string>
    <key>CFBundleDisplayName</key><string>Adele</string>
    <key>CFBundleIdentifier</key><string>tech.spadea.adele-mac</string>
    <key>CFBundleExecutable</key><string>AdeleMac</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
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

echo
echo "✅ $APP  (unsigned, self-contained)"
echo "   First open: right-click → Open, or: xattr -dr com.apple.quarantine \"$APP\""
echo "   To sign + notarize later, you'll need an Apple Developer ID identity."
