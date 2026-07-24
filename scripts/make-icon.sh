#!/usr/bin/env bash
# Regenerate Resources/AppIcon.icns from the source artwork (assets/adele.png).
#
# The source is the Adelie penguin shared with the GTK client
# (adele-gtk assets/adele.png). We composite it centered on a transparent square
# canvas (CoreGraphics, via icon-compositor.swift — it preserves alpha, which
# `sips` padding does not), emit the ten macOS iconset sizes, and pack an .icns.
# Committed output means the bundle build needs no image tooling; run this only
# when the source art changes.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$MAC_DIR"

SRC="assets/adele.png"
MASTER="$(mktemp -d)/master1024.png"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET" Resources

echo ">> compositing $SRC -> 1024 square master"
swiftc -O "$SCRIPT_DIR/icon-compositor.swift" -o "$(dirname "$MASTER")/compositor"
"$(dirname "$MASTER")/compositor" "$SRC" "$MASTER" 1024

echo ">> generating iconset"
for pair in 16:16 16@2x:32 32:32 32@2x:64 128:128 128@2x:256 256:256 256@2x:512 512:512 512@2x:1024; do
  name="${pair%%:*}"; size="${pair##*:}"
  sips -z "$size" "$size" "$MASTER" --out "$ICONSET/icon_${name}.png" >/dev/null
done

echo ">> packing Resources/AppIcon.icns"
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "✅ Resources/AppIcon.icns"
