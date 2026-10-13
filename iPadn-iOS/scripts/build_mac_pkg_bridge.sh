#!/bin/bash
# Build the Mac App Store package bridge for iPhoneOS arm64:
#   build/macpkg/libunicorn.a        no-JIT Unicorn TCI interpreter (GPL-2.0)
#   build/macpkg/libiPadnMacPKG.a    Go c-archive: MacPKGBridge/bridge.go + ipatool (MIT)
#   build/macpkg/link-flags.txt      linker flags for the app target
# Sources are fetched at pinned commits; nothing from Apple is downloaded here.
# The app downloads Apple's runtime files itself on first use.
set -euo pipefail

IPATOOL_COMMIT="4484b55d366e177ae6c89758c61588712c572fad"
TCI_COMMIT="53471ef9cf480fab094bf13db3e5d2f9e2c30dc5"
DEPLOYMENT_TARGET="17.0"
project_root="$(cd "$(dirname "$0")/.." && pwd)"
output="$project_root/build/macpkg"
work="$project_root/build/macpkg-work"

for tool in xcrun cmake go git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool is required to build the Mac PKG bridge." >&2; exit 1; }
done

rm -rf "$work" "$output"
mkdir -p "$work" "$output"
cd "$work"

git clone --no-checkout --filter=blob:none https://github.com/Naville/unicorn.git unicorn
git -C unicorn checkout --detach "$TCI_COMMIT"
test "$(git -C unicorn rev-parse HEAD)" = "$TCI_COMMIT"
git clone --no-checkout --filter=blob:none https://github.com/majd/ipatool.git ipatool
git -C ipatool checkout --detach "$IPATOOL_COMMIT"
test "$(git -C ipatool rev-parse HEAD)" = "$IPATOOL_COMMIT"
# Lift ipatool's 1-minute per-guest-call bound: the interpreter is roughly
# twice as slow as the desktop JIT and must not abort StoreAgent start-up.
patch -d ipatool -p1 < "$project_root/scripts/ipatool-guest-timeout.patch"

SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="$(xcrun --sdk iphoneos --find clang)"
export SDKROOT CC IPHONEOS_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"

cmake -S unicorn -B unicorn-build \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SDKROOT" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DCMAKE_C_FLAGS="-target arm64-apple-ios$DEPLOYMENT_TARGET" \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DUNICORN_ARCH=x86 -DUNICORN_INTERPRETER=ON \
  -DUNICORN_BUILD_TESTS=OFF -DUNICORN_INSTALL=OFF
# Never ship a JIT build: ordinary signed iPhone apps cannot execute it.
grep -Eq '^UNICORN_INTERPRETER:BOOL=ON$' unicorn-build/CMakeCache.txt
cmake --build unicorn-build --parallel 4
cp unicorn-build/libunicorn.a "$output/libunicorn.a"
xcrun nm -g "$output/libunicorn.a" | grep -q ' T _uc_emu_start$'

mkdir -p ipatool/tools/ipadn-macpkg
cp "$project_root/MacPKGBridge/bridge.go" ipatool/tools/ipadn-macpkg/bridge.go
(
  cd ipatool
  export GOOS=ios GOARCH=arm64 CGO_ENABLED=1
  export CGO_CFLAGS="-target arm64-apple-ios$DEPLOYMENT_TARGET -isysroot $SDKROOT"
  export CGO_LDFLAGS="-target arm64-apple-ios$DEPLOYMENT_TARGET -isysroot $SDKROOT"
  go build -trimpath -buildmode=c-archive -o "$output/libiPadnMacPKG.a" ./tools/ipadn-macpkg
)
rm -f "$output/libiPadnMacPKG.h"
for symbol in iPadnMacPKGDecrypt iPadnMacPKGStatus iPadnMacPKGCancel; do
  xcrun nm -g "$output/libiPadnMacPKG.a" | grep -q " T _$symbol\$"
done

cp unicorn/COPYING "$output/Unicorn-GPL-2.0.txt"
cp ipatool/LICENSE "$output/ipatool-MIT.txt"
# purego resolves uc_* and the app resolves iPadnMacPKG* with dlsym, so both
# archives are force-loaded and their globals kept through dead stripping.
echo "-Wl,-force_load,$output/libiPadnMacPKG.a -Wl,-force_load,$output/libunicorn.a -Wl,-export_dynamic -lresolv -liconv -lz -lc++ -framework Security -framework CoreFoundation" > "$output/link-flags.txt"
du -h "$output"/*.a
echo "Mac PKG bridge built in $output"
