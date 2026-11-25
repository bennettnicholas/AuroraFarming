#!/bin/bash
# Build the Rust core (core/aurora-core) for iOS and package it for Xcode:
#   ios/Generated/aurora_core.swift     Swift bindings (UniFFI)
#   ios/AuroraCore.xcframework          static library, device + simulator
# Re-run after changing any Rust code or bumping the open_oura revision.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
GEN="$ROOT/ios/Generated"
OUT="$ROOT/ios/AuroraCore.xcframework"
export IPHONEOS_DEPLOYMENT_TARGET=17.0

command -v cargo >/dev/null || { echo "Rust is required: https://rustup.rs"; exit 1; }
for t in aarch64-apple-ios aarch64-apple-ios-sim; do
  rustup target list --installed | grep -qx "$t" || rustup target add "$t"
done

echo "==> Swift bindings"
cargo build -p aurora-core
HOST_LIB="$ROOT/target/debug/libaurora_core.dylib"
[ -f "$HOST_LIB" ] || HOST_LIB="$ROOT/target/debug/libaurora_core.so"
rm -rf "$GEN" && mkdir -p "$GEN/headers"
cargo run -q -p aurora-core --bin uniffi-bindgen -- generate \
  --library "$HOST_LIB" --language swift --out-dir "$GEN"
cp "$GEN/aurora_coreFFI.h" "$GEN/headers/aurora_coreFFI.h"
cp "$GEN/aurora_coreFFI.modulemap" "$GEN/headers/module.modulemap"

if ! command -v xcodebuild >/dev/null; then
  echo "xcodebuild not found: bindings generated, skipping the iOS libraries (run on a Mac)."
  exit 0
fi

echo "==> Rust core for device + simulator (release)"
cargo build -p aurora-core --release --target aarch64-apple-ios
cargo build -p aurora-core --release --target aarch64-apple-ios-sim

echo "==> AuroraCore.xcframework"
rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library "$ROOT/target/aarch64-apple-ios/release/libaurora_core.a" -headers "$GEN/headers" \
  -library "$ROOT/target/aarch64-apple-ios-sim/release/libaurora_core.a" -headers "$GEN/headers" \
  -output "$OUT"
echo "✓ $OUT"
