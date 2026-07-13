# adele-mac — build / test / run recipes.
#
# Requires: Swift 6 toolchain, a Rust toolchain (cargo), and the client-ui-common
# checkout as a sibling directory (standard adelie-ai layout). `just --list` for
# the menu. Cluster ops live in scripts/ (enable-bedrock.sh, make-config-writable.sh).

default:
    @just --list

# Build the shared Rust core (libadele_client_core) and stage its C header.
core config="debug":
    ./scripts/build-core.sh {{config}}

# Build the SwiftUI app (debug); stages the core first.
build: core
    swift build --product AdeleMac

# Run the Swift Testing suite (wires the CLT Swift Testing framework + stages the core).
test *args:
    ./scripts/test.sh {{args}}

# Build a dev .app bundle and launch it (proper bundle so keyboard focus works).
run:
    ./scripts/run-app.sh

# Build a self-contained, UNSIGNED release .app (core dylib bundled inside).
app:
    ./scripts/build-app.sh

# Headless end-to-end smoke driver against a daemon (login → connect → prompt →
# stream). Set ADELE_WS_PASS in your env; override url/user as needed. Extra env:
# ADELE_MGMT=1 (exercise management), ADELE_PROMPT, ADELE_TIMEOUT.
#   just smoke                       # lab LB, user adele (needs ADELE_WS_PASS)
#   just smoke ws://127.0.0.1:11339/ws
smoke url="ws://192.168.1.2:11339/ws" user="adele":
    ./scripts/build-core.sh >/dev/null
    ADELE_WS_URL="{{url}}" ADELE_WS_USER="{{user}}" swift run AdeleSmoke

# Remove build artifacts.
clean:
    rm -rf .build
