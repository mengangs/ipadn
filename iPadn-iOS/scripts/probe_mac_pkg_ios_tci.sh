#!/bin/bash
# No-JIT x86-64 TCI interpreter experiment for normal signed iPhone apps.
# Separate from ipatool's JIT Unicorn and the real Mac PKG downloader.
set -euo pipefail
SOURCE_COMMIT="53471ef9cf480fab094bf13db3e5d2f9e2c30dc5"
PROJECT_ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKDIR="${RUNNER_TEMP:-/tmp}/ipadn-macpkg-tci-probe"
SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="$(xcrun --sdk iphoneos --find clang)"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/out"
cd "$WORKDIR"

# TCI fork implements interpretation of QEMU TCG bytecode without JIT.
# Fixed commit is documented alongside its GPL-2.0 source code.
git clone --no-checkout --filter=blob:none https://github.com/Naville/unicorn.git source
git -C source checkout --detach "$SOURCE_COMMIT"
test "$(git -C source rev-parse HEAD)" = "$SOURCE_COMMIT"

cmake -S source -B build \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SDKROOT" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DCMAKE_C_FLAGS="-target arm64-apple-ios15.0" \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DUNICORN_ARCH=x86 -DUNICORN_INTERPRETER=ON \
  -DUNICORN_BUILD_TESTS=OFF -DUNICORN_INSTALL=OFF

# Abort if a future upstream revision disables the no-JIT build mode.
grep -Eq '^UNICORN_INTERPRETER:BOOL=ON$' build/CMakeCache.txt
cmake --build build --parallel 4
test -s build/libunicorn.a
xcrun nm -g build/libunicorn.a | grep -E ' T _uc_emu_start$'
xcrun nm -g build/libunicorn.a | grep -E ' T _uc_reg_read$'

APP="$WORKDIR/out/MacPKGTCIProbe.app"
mkdir -p "$APP" "$WORKDIR/out/Payload"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.ipadn.macpkg-tci-runtime-probe</string>
<key>CFBundleExecutable</key><string>MacPKGTCIProbe</string>
<key>CFBundleName</key><string>Mac PKG TCI Probe</string>
<key>CFBundleDisplayName</key><string>Mac PKG 无JIT测试</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleShortVersionString</key><string>0.5</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSRequiresIPhoneOS</key><true/>
<key>MinimumOSVersion</key><string>15.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST

# Only fully signed, ordinary ARM64 iPhone instructions in this app's Mach-O;
# the x86 guest program runs inside C's TCI bytecode interpreter.
"$CC" -target arm64-apple-ios15.0 -isysroot "$SDKROOT" \
  -fobjc-arc -Isource/include \
  "$PROJECT_ROOT/iPadn-iOS/scripts/mac_pkg_tci_probe.m" \
  -Wl,-force_load,"$WORKDIR/build/libunicorn.a" \
  -framework UIKit -framework Foundation -framework CoreFoundation \
  -liconv -lz -lc++ \
  -o "$APP/MacPKGTCIProbe"
cp source/COPYING "$APP/GPL-2.0.txt"
cat > "$APP/Source.txt" <<TXT
This diagnostic links Unicorn TCI under GPL-2.0.
Exact upstream source: https://github.com/Naville/unicorn/tree/$SOURCE_COMMIT
Upstream implementation includes QEMU Tiny Code Interpreter (TCI).
Unicorn sources are licensed GPL-2.0; see GPL-2.0.txt.
TXT

plutil -lint "$APP/Info.plist"
xcrun vtool -show-build "$APP/MacPKGTCIProbe"
cp -R "$APP" "$WORKDIR/out/Payload/"
(cd "$WORKDIR/out" && /usr/bin/zip -qr -X MacPKGTCIProbe-unsigned.ipa Payload)
test -s "$WORKDIR/out/MacPKGTCIProbe-unsigned.ipa"
du -h "$WORKDIR/out/MacPKGTCIProbe-unsigned.ipa"
echo "TCI no-JIT static build and unsigned IPA packaging passed."
echo "No real iPhone execution, StoreAgent or PKG decryption has been tested by CI."
