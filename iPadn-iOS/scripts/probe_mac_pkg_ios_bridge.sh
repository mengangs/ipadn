#!/bin/bash
# Build-time feasibility test only. No Apple credentials, DRM keys, StoreAgent
# binaries, or user data are used. This archive is NOT a working PKG decrypter.
set -euo pipefail

UPSTREAM_COMMIT="4484b55d366e177ae6c89758c61588712c572fad" # ipatool v2.7.0
UNICORN_URL="https://github.com/unicorn-engine/unicorn/archive/refs/tags/2.1.4.tar.gz"
UNICORN_SHA256="ea8863f095a0136388694e5a6063afd9bb7650e30243dd6251af59c5ce5601f4"

PROJECT_ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="$(xcrun --sdk iphoneos --find clang)"
WORKDIR="${RUNNER_TEMP:-/tmp}/ipadn-macpkg-static-probe"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/out"
cd "$WORKDIR"

git clone --no-checkout --filter=blob:none https://github.com/majd/ipatool.git upstream
git -C upstream checkout --detach "$UPSTREAM_COMMIT"
curl -fL --retry 3 "$UNICORN_URL" -o unicorn.tar.gz
echo "$UNICORN_SHA256  unicorn.tar.gz" | shasum -a 256 -c -
tar -xzf unicorn.tar.gz
patch -d unicorn-2.1.4 -p1 < upstream/tools/patches/unicorn-ios.patch

# Unicorn's build target is the emulated guest CPU (x86). It is NOT the
# native iPhone executable architecture (arm64, set above). See ipatool's
# own tools/build-ios.sh for matching UNICORN_ARCH=x86.
cmake -S unicorn-2.1.4 -B unicorn-build \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SDKROOT" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DCMAKE_C_FLAGS="-target arm64-apple-ios15.0" \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DUNICORN_ARCH=x86 -DUNICORN_BUILD_TESTS=OFF -DUNICORN_INSTALL=OFF
cmake --build unicorn-build --parallel 4
test -s unicorn-build/libunicorn.a

mkdir -p upstream/tools/iosbridge
cat > upstream/tools/iosbridge/main.go <<'GOEOF'
package main

/*
#include <stdint.h>
#include <stdbool.h>
extern unsigned int uc_version(unsigned int *major, unsigned int *minor);
extern bool uc_arch_supported(int arch);
*/
import "C"
import (
    "context"
    "fmt"
    "unsafe"

    "github.com/majd/ipatool/v2/internal/sap/unicorn"
)

func storeError(out *C.char, capacity C.int32_t, message string) {
    if out == nil || capacity < 2 || capacity > 4096 { return }
    buf := unsafe.Slice((*byte)(unsafe.Pointer(out)), int(capacity))
    copied := copy(buf[:len(buf)-1], message)
    buf[copied] = 0
}

//export iPadnMacUnicornProbe
func iPadnMacUnicornProbe(out *C.char, capacity C.int32_t) C.int32_t {
    // The *host binary* must be iPhoneOS arm64, but the *guest ISA* here
    // must be x86-64, as used by Apple's Mac StoreAgent.
    var major, minor C.uint
    C.uc_version(&major, &minor)
    if C.uc_arch_supported(4) == C.bool(false) { // UC_ARCH_X86 = 4
        storeError(out, capacity, fmt.Sprintf(
            "已链接 Unicorn %d.%d，但不包含 x86-64 模拟目标。", uint32(major), uint32(minor)))
        return -2
    }
    engine, err := unicorn.New(context.Background())
    if err != nil {
        storeError(out, capacity, fmt.Sprintf("Unicorn %d.%d / x86-64: %v",
            uint32(major), uint32(minor), err))
        return -1
    }
    defer engine.Close()
    storeError(out, capacity, fmt.Sprintf("Unicorn %d.%d / x86-64 初始化成功",
        uint32(major), uint32(minor)))
    return 0
}
func main() {}
GOEOF

export SDKROOT CC
export IPHONEOS_DEPLOYMENT_TARGET=15.0
export GOOS=ios GOARCH=arm64 CGO_ENABLED=1
export CGO_LDFLAGS="${CGO_LDFLAGS:-} -Wl,-force_load,$WORKDIR/unicorn-build/libunicorn.a -Wl,-export_dynamic"
cd upstream
go build -buildmode=c-archive -o "$WORKDIR/out/libipadnMacBridge.a" ./tools/iosbridge
test -s "$WORKDIR/out/libipadnMacBridge.a"
xcrun lipo -info "$WORKDIR/out/libipadnMacBridge.a"
xcrun nm -g "$WORKDIR/out/libipadnMacBridge.a" | grep "iPadnMacUnicornProbe"

# Link against the actual iPhoneOS SDK to check the archive can be referenced
# by a standard iOS application (not just built as a jailbroken CLI).
cat > "$WORKDIR/probe.m" <<'OBJC'
#include <stdint.h>
extern int32_t iPadnMacUnicornProbe(char *error, int32_t capacity);
int main(void) {
    char diagnostic[512] = {0};
    return (int)iPadnMacUnicornProbe(diagnostic, (int32_t)sizeof(diagnostic));
}
OBJC
"$CC" -target arm64-apple-ios15.0 -isysroot "$SDKROOT" \
  "$WORKDIR/probe.m" "$WORKDIR/out/libipadnMacBridge.a" \
  -framework Foundation -framework Security -framework CoreFoundation \
  -lresolv -liconv -lz -lc++ -Wl,-export_dynamic \
  -o "$WORKDIR/out/probe-ios-arm64"
xcrun file "$WORKDIR/out/probe-ios-arm64"
du -h "$WORKDIR/out/libipadnMacBridge.a" "$WORKDIR/out/probe-ios-arm64"

# Build a minimal, separately installable iOS app that invokes Unicorn only
# after a user tap. An unsigned IPA is an artifact for deliberate on-device
# verification with the user's own code-signing profile.
APP="$WORKDIR/out/MacPKGProbe.app"
mkdir -p "$APP" "$WORKDIR/out/Payload"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.ipadn.macpkg-runtime-probe</string>
<key>CFBundleExecutable</key><string>MacPKGProbe</string>
<key>CFBundleName</key><string>Mac PKG Runtime Probe</string>
<key>CFBundleDisplayName</key><string>Mac PKG 测试</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleShortVersionString</key><string>0.2</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSRequiresIPhoneOS</key><true/>
<key>MinimumOSVersion</key><string>15.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
"$CC" -target arm64-apple-ios15.0 -isysroot "$SDKROOT" \
  -fobjc-arc "$PROJECT_ROOT/iPadn-iOS/scripts/mac_pkg_runtime_probe.m" \
  "$WORKDIR/out/libipadnMacBridge.a" \
  -framework UIKit -framework Foundation -framework Security -framework CoreFoundation \
  -lresolv -liconv -lz -lc++ -Wl,-export_dynamic \
  -o "$APP/MacPKGProbe"
plutil -lint "$APP/Info.plist"
xcrun vtool -show-build "$APP/MacPKGProbe"
cp -R "$APP" "$WORKDIR/out/Payload/"
(cd "$WORKDIR/out" && /usr/bin/zip -qr -X MacPKGProbe-unsigned.ipa Payload)
test -s "$WORKDIR/out/MacPKGProbe-unsigned.ipa"
du -h "$WORKDIR/out/MacPKGProbe-unsigned.ipa"

echo "Static build/link and unsigned diagnostic IPA packaging passed."
echo "A real non-jailbroken iPhone test is STILL required for runtime JIT/W^X, memory and code-signing compatibility."
