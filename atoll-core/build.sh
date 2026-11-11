#!/bin/bash
#
# Build the Rust core (atoll-core) for the Atoll Xcode target.
#
# Produces target/<target>/<profile>/libatoll_core.a — the exact path the
# DynamicIsland target links against (LIBRARY_SEARCH_PATHS + -latoll_core) —
# and a copy under dist/ for manual use. Runs from Xcode's "Build atoll-core
# (Rust)" build phase as well as by hand, so clean checkouts build with no
# extra setup beyond a Rust toolchain.
#
# Usage:
#   ./build.sh                 # release build for the host arch
#   ./build.sh --if-needed     # skip when the .a is newer than every source
#   ./build.sh --debug         # debug build (not used by Xcode)
#
# Environment:
#   ATOLL_RUST_TARGET          override the Rust target triple
#   ARCHS / CURRENT_ARCH       Xcode passes these; arm64 maps to aarch64-apple-darwin
#
set -euo pipefail
cd "$(dirname "$0")"

# Xcode's build environment has a minimal PATH; rustup shims live in
# ~/.cargo/bin and Homebrew in /opt/homebrew/bin.
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

IF_NEEDED=0
PROFILE="release"
for arg in "$@"; do
    case "$arg" in
        --if-needed) IF_NEEDED=1 ;;
        --debug)     PROFILE="debug" ;;
        --release)   PROFILE="release" ;;
        *)
            echo "error: unknown argument '$arg'" >&2
            exit 2
            ;;
    esac
done

resolve_target() {
    if [[ -n "${ATOLL_RUST_TARGET:-}" ]]; then
        echo "$ATOLL_RUST_TARGET"
        return
    fi

    # Under Xcode, build for the architecture the target is being built for.
    local archs="${ARCHS:-${CURRENT_ARCH:-}}"
    if [[ -n "$archs" ]]; then
        if [[ "$archs" == *x86_64* ]]; then
            cat >&2 <<'EOF'
error: atoll-core currently ships arm64 only.
       The x86_64 slice needs a second cargo build plus lipo into a universal
       static library; see atoll-core/README.md ("Targets"). Building for
       arm64 (the default on Apple silicon) is fully supported.
EOF
            exit 1
        fi
        if [[ "$archs" == *arm64* ]]; then
            echo "aarch64-apple-darwin"
            return
        fi
        echo "error: unsupported Xcode ARCHS='$archs' (expected arm64)." >&2
        exit 1
    fi

    case "$(uname -m)" in
        arm64)  echo "aarch64-apple-darwin" ;;
        x86_64) echo "x86_64-apple-darwin" ;;
        *)
            echo "error: unsupported host architecture $(uname -m)." >&2
            exit 1
            ;;
    esac
}

TARGET="$(resolve_target)"
LIB="target/$TARGET/$PROFILE/libatoll_core.a"
# Cargo may consider the library up to date and leave its mtime untouched, so
# compare sources against a stamp written after a successful build instead.
STAMP="target/$TARGET/$PROFILE/.atoll-core-build-stamp"

if ! command -v cargo >/dev/null 2>&1; then
    cat >&2 <<'EOF'
error: cargo not found.

atoll-core is written in Rust and the Xcode target links its static library.
Install the toolchain (https://rustup.rs) and build again — the "Build
atoll-core (Rust)" build phase runs this script automatically:

    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

The channel is pinned by atoll-core/rust-toolchain.toml.
EOF
    exit 1
fi

# Xcode runs the phase on every build; cargo itself is incremental, but a
# timestamp check keeps the no-op case at ~10 ms instead of ~100 ms.
if [[ "$IF_NEEDED" -eq 1 && -f "$LIB" && -f "$STAMP" ]]; then
    changed="$(find src Cargo.toml Cargo.lock rust-toolchain.toml \
        -type f -newer "$STAMP" -print -quit 2>/dev/null || true)"
    if [[ -z "$changed" ]]; then
        echo "atoll-core: up to date ($LIB)"
        exit 0
    fi
    echo "atoll-core: rebuilding — $changed is newer than the last build"
fi

echo "atoll-core: cargo build ($PROFILE, $TARGET)"
if [[ "$PROFILE" == "release" ]]; then
    cargo build --locked --release --target "$TARGET"
else
    cargo build --locked --target "$TARGET"
fi

mkdir -p dist "$(dirname "$STAMP")"
cp "$LIB" dist/
touch "$STAMP"
echo "atoll-core: built $LIB ($(du -h "$LIB" | cut -f1 | tr -d ' '))"
