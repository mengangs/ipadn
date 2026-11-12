#!/bin/bash
# Build the native installation library for iPhoneOS arm64:
#   build/native/libipadn_native.a   Rust staticlib: NativeInstall + idevice (MIT)
#   build/native/link-flags.txt      linker flags for the app target
# Pure Rust, so it cross-compiles on macOS and Linux without an Apple SDK.
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
output="$project_root/build/native"
target="aarch64-apple-ios"
# Rust's standard library for this target is built for a newer iOS than the
# app supports unless the deployment target is stated.
export IPHONEOS_DEPLOYMENT_TARGET="17.0"
# Kept out of the source tree; override to reuse a cache.
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$project_root/build/native-work}"

command -v cargo >/dev/null 2>&1 || { echo "cargo is required to build the native installation library." >&2; exit 1; }
rustup target list --installed 2>/dev/null | grep -qx "$target" || rustup target add "$target"

rm -rf "$output"
mkdir -p "$output"
cargo build --manifest-path "$project_root/NativeInstall/Cargo.toml" --locked --release --target "$target"
cp "$CARGO_TARGET_DIR/$target/release/libipadn_native.a" "$output/libipadn_native.a"

# The app resolves iPadnNative* with dlsym, so the archive is force-loaded and
# its globals kept through dead stripping.
for symbol in iPadnNativeInstall iPadnNativeLookup iPadnNativeList iPadnNativeCancel iPadnNativeFree iPadnNativePair iPadnNativePairCancel; do
  grep -aq "_$symbol" "$output/libipadn_native.a" || { echo "missing symbol $symbol" >&2; exit 1; }
done
cp "$project_root/NativeInstall/LICENSE-idevice.txt" "$output/idevice-MIT.txt"
echo "-Wl,-force_load,$output/libipadn_native.a -Wl,-export_dynamic -lresolv -liconv" > "$output/link-flags.txt"
du -h "$output"/*.a
echo "Native installation library built in $output"
