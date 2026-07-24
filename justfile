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

# --- Built-in MCP servers (da#538) -------------------------------------------
# The MCP servers are compiled INTO the shared Rust core (client-ui-common/ffi)
# and hosted in-process, selected by cargo features. The SwiftUI app links
# whatever the core was built with, so choosing a server set is a core-build
# concern — these recipes set `ADELE_CORE_FEATURES` and re-run scripts/build-core.sh.
#
#   just build-with-mcp                    # the core set (fileio/terminal/tasks/web)
#   just build-with-mcp weather geocode    # core set + weather + geocode
#   just build-with-mcp extras             # core set + the whole broad set
#   just build-with-mcp all                # everything compiled in
#   just build-with-mcp only fileio web    # EXACTLY fileio + web
#   just build-with-mcp none               # no built-in servers at all
#
# NOTE the difference from adele-gtk/adele-tui: the ffi crate's cargo default is
# EMPTY (no built-ins), because adele-kde links the same cdylib and its build
# must stay unchanged. So a bare `just build` still compiles in nothing, while a
# bare `just build-with-mcp` means the core set — which is why the recipes below
# always pass an explicit `--features`.

# What a bare `just build-with-mcp` (no server arguments) selects.
mcp_default_features := "builtin-core"

# Print the cargo feature flags a given MCP selection maps to, without building.
mcp-args *SERVERS:
    #!/usr/bin/env bash
    set -euo pipefail
    core_dir="${ADELE_CORE_DIR:-$(cd "{{justfile_directory()}}/.." && pwd)/client-ui-common}"
    manifest="$core_dir/ffi/Cargo.toml"
    if [ ! -f "$manifest" ]; then
      echo "mcp-args: client-ui-common/ffi not found at $core_dir/ffi" >&2
      exit 1
    fi
    # Read the selectable servers out of the ffi crate's `[features]` block, so
    # adding an `mcp-*` feature there is all it takes for these recipes to accept it.
    avail="$(awk '/^\[features\]/{f=1;next} /^\[/{f=0} f' "$manifest" \
        | grep -oE '^mcp-[a-z0-9-]+' | sort -u)"
    sel=""
    add() { case ",$sel," in *",$1,"*) ;; *) sel="${sel:+$sel,}$1" ;; esac; }
    first=1
    exact=0
    raw="{{SERVERS}}"
    for tok in $raw; do
      case "$tok" in
        only)
          if [ "$first" != 1 ]; then echo "mcp-args: 'only' must be the first argument" >&2; exit 2; fi
          exact=1
          ;;
        none)
          if [ "$first" != 1 ]; then echo "mcp-args: 'none' must be the first argument" >&2; exit 2; fi
          # The crate default is already "no built-ins", so this is simply an
          # empty feature set — no `--no-default-features` needed.
          echo
          exit 0
          ;;
        core)   add builtin-core ;;
        extras) add builtin-extras ;;
        all)    add builtin-core; add builtin-extras ;;
        *)
          case "$tok" in
            radio) f=mcp-internet-radio ;;
            osm)   f=mcp-openstreetmap ;;
            mcp-*) f="$tok" ;;
            *)     f="mcp-$tok" ;;
          esac
          if ! printf '%s\n' "$avail" | grep -qx -- "$f"; then
            {
              echo "mcp-args: unknown MCP server '$tok'"
              echo "available:"
              printf '%s\n' "$avail" | sed 's/^mcp-/  /'
              echo "  (plus the umbrellas: core, extras, all — and none / only)"
            } >&2
            exit 2
          fi
          add "$f"
          ;;
      esac
      first=0
    done
    # Naming a server is ADDITIVE to the default set, matching adele-gtk/adele-tui
    # where `--features mcp-weather` rides on top of cargo's default `builtin-core`.
    # The ffi crate's default is empty (adele-kde shares this core), so the base
    # set has to be added back explicitly here or `just build-with-mcp weather`
    # would silently mean "weather and nothing else".
    # `only` is exactly the escape hatch that suppresses this.
    if [ "$exact" = 0 ]; then
      add "{{mcp_default_features}}"
    fi
    if [ -n "$sel" ]; then echo "--features $sel"; else echo; fi

# Also flags whether each server's sibling crate is actually checked out.
# List the built-in MCP servers the core can compile in, and which are in the default set.
mcp-list:
    #!/usr/bin/env bash
    set -euo pipefail
    core_dir="${ADELE_CORE_DIR:-$(cd "{{justfile_directory()}}/.." && pwd)/client-ui-common}"
    manifest="$core_dir/ffi/Cargo.toml"
    if [ ! -f "$manifest" ]; then
      echo "mcp-list: client-ui-common/ffi not found at $core_dir/ffi" >&2
      exit 1
    fi
    feats="$(awk '/^\[features\]/{f=1;next} /^\[/{f=0} f' "$manifest")"
    core_list=" $(printf '%s' "$feats" | tr '\n' ' ' \
        | sed -E 's/.*builtin-core *= *\[([^]]*)\].*/\1/' \
        | grep -oE 'mcp-[a-z0-9-]+' | tr '\n' ' ')"
    echo "built-in MCP servers compiled into the core (feature / in default set / crate):"
    for f in $(printf '%s\n' "$feats" | grep -oE '^mcp-[a-z0-9-]+' | sort -u); do
      dep="$(printf '%s\n' "$feats" | sed -nE "s/^$f *= *\[.*dep:([A-Za-z0-9_-]+).*/\1/p")"
      path=""
      if [ -n "$dep" ]; then
        path="$(sed -nE "s/^$dep *= *\{.*path *= *\"([^\"]+)\".*/\1/p" "$manifest" | sed -n 1p)"
      fi
      case "$core_list " in *" $f "*) tag="core" ;; *) tag="opt-in" ;; esac
      note=""
      if [ -n "$path" ] && [ ! -d "$core_dir/ffi/$path" ]; then
        note="   ** sibling crate not checked out: $path"
      fi
      printf '  %-16s %-8s %s%s\n' "${f#mcp-}" "$tag" "${dep:-?}" "$note"
    done
    echo
    echo "umbrellas: core, extras (the broad set), all"
    echo "modifiers: 'only <servers…>' for an exact set, 'none' for no built-ins"
    echo "a bare 'just build-with-mcp' selects: {{mcp_default_features}}"
    echo "(plain 'just build' compiles in NO built-ins — adele-kde shares this core)"

# Build the Rust core with a chosen set of built-in MCP servers.
core-with-mcp *SERVERS:
    #!/usr/bin/env bash
    set -euo pipefail
    args="$(just mcp-args {{SERVERS}})"
    echo "+ ADELE_CORE_FEATURES='$args' ./scripts/build-core.sh"
    ADELE_CORE_FEATURES="$args" ./scripts/build-core.sh

# This is the one to reach for day to day.
# Build the SwiftUI app against a core carrying a chosen set of built-in MCP servers.
build-with-mcp *SERVERS:
    #!/usr/bin/env bash
    set -euo pipefail
    args="$(just mcp-args {{SERVERS}})"
    echo "+ ADELE_CORE_FEATURES='$args' ./scripts/build-core.sh"
    ADELE_CORE_FEATURES="$args" ./scripts/build-core.sh
    swift build --product AdeleMac

# `McpBuiltinInventoryTests` asserts against whichever core is linked. To PIN the
# exact set it must report, name it in ADELE_EXPECT_BUILTINS, e.g.
#   ADELE_EXPECT_BUILTINS=fileio,terminal,tasks,web just test-with-mcp
# (not derived from SERVERS automatically: terminal and tasks have fallible
# constructors and may legitimately be absent in a hostile environment).
# Run the Swift test suite against a core carrying a chosen set of built-ins.
test-with-mcp *SERVERS:
    #!/usr/bin/env bash
    set -euo pipefail
    args="$(just mcp-args {{SERVERS}})"
    echo "+ ADELE_CORE_FEATURES='$args' ./scripts/test.sh"
    ADELE_CORE_FEATURES="$args" ./scripts/test.sh

# Build a dev .app bundle with a chosen set of built-ins and launch it.
run-with-mcp *SERVERS:
    #!/usr/bin/env bash
    set -euo pipefail
    args="$(just mcp-args {{SERVERS}})"
    echo "+ ADELE_CORE_FEATURES='$args' ./scripts/run-app.sh"
    ADELE_CORE_FEATURES="$args" ./scripts/run-app.sh

# Build the self-contained release .app with a chosen set of built-ins.
app-with-mcp *SERVERS:
    #!/usr/bin/env bash
    set -euo pipefail
    args="$(just mcp-args {{SERVERS}})"
    echo "+ ADELE_CORE_FEATURES='$args' ./scripts/build-app.sh"
    ADELE_CORE_FEATURES="$args" ./scripts/build-app.sh

# Run after adding a server or moving one between the sets — a stray `#[cfg]`
# typically compiles in one combo and breaks another. The "no built-ins" leg is
# what adele-kde ships, so this also guards against regressing KDE.
# Clippy + test the core in three feature combos: no built-ins, core set, everything.
mcp-matrix:
    #!/usr/bin/env bash
    set -euo pipefail
    core_dir="${ADELE_CORE_DIR:-$(cd "{{justfile_directory()}}/.." && pwd)/client-ui-common}"
    for sel in none "" all; do
      args="$(just mcp-args $sel)"
      echo "== core ${args:-(no built-ins)}"
      ( cd "$core_dir" && cargo clippy -p client-ui-ffi --all-targets $args -- -D warnings )
      ( cd "$core_dir" && cargo test -p client-ui-ffi $args )
    done
