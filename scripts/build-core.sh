#!/usr/bin/env bash
# Build the shared Rust core (client-ui-common/ffi -> libadele_client_core) and
# stage its cbindgen-generated C header where the SwiftPM `CAdeleCore` module can
# see it.
#
# This is the macOS analog of adele-kde's CMake `adele_core_build` target: the
# UI links ONE self-contained cdylib that owns the reducer + transport; all
# model/controller logic stays in Rust. Phase 1 builds a host-arch debug dylib
# and links it with a dev RPATH; universal (lipo) + bundling is a later phase.
set -euo pipefail

CONFIG="${1:-debug}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Default to the sibling checkout; override with ADELE_CORE_DIR for worktrees.
CORE_DIR="${ADELE_CORE_DIR:-$(cd "$MAC_DIR/.." && pwd)/client-ui-common}"

if [[ ! -f "$CORE_DIR/ffi/Cargo.toml" ]]; then
    echo "error: client-ui-common/ffi not found at $CORE_DIR/ffi" >&2
    echo "       expected the client-ui-common checkout as a sibling of adele-mac." >&2
    exit 1
fi

RELEASE_FLAG=""
[[ "$CONFIG" == "release" ]] && RELEASE_FLAG="--release"

echo ">> cargo build -p client-ui-ffi ($CONFIG)"
# shellcheck disable=SC2086  # intentional word-split of the (empty-or-single) flag
( cd "$CORE_DIR" && cargo build -p client-ui-ffi $RELEASE_FLAG )

HEADER_SRC="$CORE_DIR/ffi/include/adele_client_core.h"
HEADER_DST="$MAC_DIR/Sources/CAdeleCore/include/adele_client_core.h"
# The include/ dir is gitignored (holds only the generated header), so a fresh
# checkout/worktree won't have it — create it before staging.
mkdir -p "$(dirname "$HEADER_DST")"
cp "$HEADER_SRC" "$HEADER_DST"
echo ">> staged header -> $HEADER_DST"

echo ">> core dylib: $CORE_DIR/target/$CONFIG/libadele_client_core.dylib"
