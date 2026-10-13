#!/bin/bash
# Build-only check that ipatool's *actual* Go StoreAgent integration can be
# linked to the no-JIT Unicorn TCI engine as iPhoneOS arm64 machine code.
# It never executes StoreAgent, fetches Apple assets, or accesses credentials.
set -euo pipefail

IPATOOL_COMMIT="4484b55d366e177ae6c89758c61588712c572fad"
ROOT="${RUNNER_TEMP:-/tmp}/ipadn-macpkg-tci-probe"
SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="$(xcrun --sdk iphoneos --find clang)"
LIBRARY="$ROOT/build/libunicorn.a"
test -s "$LIBRARY" || { echo 'Build the pinned TCI library first.' >&2; exit 1; }

cd "$ROOT"
git clone --no-checkout --filter=blob:none https://github.com/majd/ipatool.git ipatool
git -C ipatool checkout --detach "$IPATOOL_COMMIT"
test "$(git -C ipatool rev-parse HEAD)" = "$IPATOOL_COMMIT"

mkdir -p ipatool/tools/ios-tci-link
cat > ipatool/tools/ios-tci-link/main.go <<'GOEOF'
package main

/*
#include <stdint.h>
*/
import "C"
import (
    "context"
    "github.com/majd/ipatool/v2/internal/sap/assets"
    "github.com/majd/ipatool/v2/internal/sap/machine"
    "github.com/majd/ipatool/v2/internal/sap/unicorn"
)

//export iPadnMacTCIStoreAgentLinkProbe
func iPadnMacTCIStoreAgentLinkProbe() C.int32_t {
    // This export forces the compiler to retain BOTH the full StoreAgent Go
    // path and the Go-to-native Unicorn calls. It must never be executed:
    // empty assets intentionally cannot constitute a valid StoreAgent.
    _, err := machine.OpenStoreAgent(context.Background(), assets.Bundle{}, nil, nil)
    if err != nil { return -1 }
    return 0
}

//export iPadnMacTCIEngineLinkProbe
func iPadnMacTCIEngineLinkProbe() C.int32_t {
    engine, err := unicorn.New(context.Background())
    if err != nil { return -1 }
    defer engine.Close()
    return 0
}
func main() {}
GOEOF

export SDKROOT
export CC
export GOOS=ios GOARCH=arm64 CGO_ENABLED=1
export CGO_CFLAGS="-target arm64-apple-ios15.0 -isysroot $SDKROOT"
export IPHONEOS_DEPLOYMENT_TARGET=15.0
cd ipatool
go build -trimpath -buildmode=c-archive -o "$ROOT/out/libMacPKGTCIStoreAgentBridge.a" ./tools/ios-tci-link
test -s "$ROOT/out/libMacPKGTCIStoreAgentBridge.a"
xcrun nm -g "$ROOT/out/libMacPKGTCIStoreAgentBridge.a" | grep 'iPadnMacTCIStoreAgentLinkProbe'
xcrun nm -g "$ROOT/out/libMacPKGTCIStoreAgentBridge.a" | grep 'iPadnMacTCIEngineLinkProbe'

cat > "$ROOT/tci-go-bridge-probe.c" <<'CEOF'
#include <stdint.h>
extern int32_t iPadnMacTCIStoreAgentLinkProbe(void);
extern int32_t iPadnMacTCIEngineLinkProbe(void);
// The executable is only linked, NEVER RUN by CI or installed on a device.
int main(void) { return iPadnMacTCIEngineLinkProbe() +
                        iPadnMacTCIStoreAgentLinkProbe(); }
CEOF
"$CC" -target arm64-apple-ios15.0 -isysroot "$SDKROOT" \
  "$ROOT/tci-go-bridge-probe.c" "$ROOT/out/libMacPKGTCIStoreAgentBridge.a" \
  -Wl,-force_load,"$LIBRARY" -Wl,-export_dynamic \
  -framework Foundation -framework Security -framework CoreFoundation \
  -lresolv -liconv -lz -lc++ \
  -o "$ROOT/out/MacPKGTCIStoreAgentBridge-link-only"
xcrun file "$ROOT/out/MacPKGTCIStoreAgentBridge-link-only"
du -h "$ROOT/out/libMacPKGTCIStoreAgentBridge.a" \
  "$ROOT/out/MacPKGTCIStoreAgentBridge-link-only"
echo "Build-only proof: Go StoreAgent code and no-JIT Unicorn TCI link together for iPhoneOS arm64."
echo "NO StoreAgent initialization, Apple asset retrieval, authorization, macOS PKG download or decryption performed."
