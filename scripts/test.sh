#!/usr/bin/env bash
# Run the Swift test suite.
#
# The Command Line Tools ship the Swift Testing framework but leave it off the
# default search/rpath, so `swift test` needs it wired in explicitly. This script
# stages the Rust core (tests link AdeleCore -> the C ABI) and runs the suite.
#
# Worktree note: set ADELE_CORE_DIR (for build-core.sh) and ADELE_CORE_LIB_DIR
# (for Package.swift's linker path) when the client-ui-common sibling layout
# doesn't hold — e.g.:
#   ADELE_CORE_DIR=/abs/client-ui-common \
#   ADELE_CORE_LIB_DIR=/abs/client-ui-common/target/debug ./scripts/test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# Stage the core dylib + generated header the test binary links against.
"$SCRIPT_DIR/build-core.sh" >/dev/null

FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib

if [[ -d "$FW/Testing.framework" ]]; then
    exec swift test \
        -Xswiftc -F -Xswiftc "$FW" \
        -Xlinker -F -Xlinker "$FW" \
        -Xlinker -rpath -Xlinker "$FW" \
        -Xlinker -rpath -Xlinker "$LIB" "$@"
else
    # Full Xcode or a toolchain with Testing on the default path.
    exec swift test "$@"
fi
