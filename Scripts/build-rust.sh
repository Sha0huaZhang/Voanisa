#!/bin/bash
#
# Build the portable Rust core as a static library for the macOS app.
#
# Debug builds only the host architecture so Xcode iteration stays fast.
# Release builds both arm64 and x86_64 and merges them with lipo.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MANIFEST="$REPO_ROOT/Rust/Cargo.toml"
BUILD_DIR="$REPO_ROOT/Rust/build"
HEADER="$REPO_ROOT/Rust/voanisa-ffi/include/voanisa_core.h"
CONFIGURATION="${CONFIGURATION:-Debug}"

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}"

mkdir -p "$BUILD_DIR"

if [[ "$CONFIGURATION" == "Debug" ]]; then
    HOST_ARCH="$(uname -m)"
    case "$HOST_ARCH" in
        arm64) TARGET="aarch64-apple-darwin" ;;
        x86_64) TARGET="x86_64-apple-darwin" ;;
        *)
            echo "error: unsupported host architecture $HOST_ARCH" >&2
            exit 1
            ;;
    esac

    echo "==> rust: debug $TARGET"
    cargo build --manifest-path "$MANIFEST" -p voanisa-ffi --target "$TARGET"
    cp "$REPO_ROOT/Rust/target/$TARGET/debug/libvoanisa_ffi.a" "$BUILD_DIR/libvoanisa_ffi.a"
else
    TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)
    for TARGET in "${TARGETS[@]}"; do
        if ! rustup target list --installed | grep -qx "$TARGET"; then
            echo "==> rust: adding $TARGET"
            rustup target add "$TARGET"
        fi
        echo "==> rust: release $TARGET"
        cargo build --manifest-path "$MANIFEST" -p voanisa-ffi --release --target "$TARGET"
    done

    echo "==> rust: lipo"
    lipo -create \
        "$REPO_ROOT/Rust/target/aarch64-apple-darwin/release/libvoanisa_ffi.a" \
        "$REPO_ROOT/Rust/target/x86_64-apple-darwin/release/libvoanisa_ffi.a" \
        -output "$BUILD_DIR/libvoanisa_ffi.a"
fi

cp "$HEADER" "$BUILD_DIR/voanisa_core.h"
echo "==> rust: $(lipo -archs "$BUILD_DIR/libvoanisa_ffi.a" 2>/dev/null || true)"
