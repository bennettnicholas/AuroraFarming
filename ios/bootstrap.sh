#!/bin/bash
# One-shot setup on a Mac: build the Rust core, generate the Xcode project, open it.
#   Needs: Xcode 15+, Rust (https://rustup.rs), XcodeGen (brew install xcodegen).
set -euo pipefail
cd "$(dirname "$0")"
command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen"; exit 1; }
./build-core.sh
xcodegen generate
echo "✓ Aurora.xcodeproj generated. Set your Team under Signing & Capabilities, pick your iPhone, and Run."
[ "${CI:-}" = "true" ] || open Aurora.xcodeproj
