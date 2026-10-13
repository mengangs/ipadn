#!/bin/bash
# Build-only check that ipatool's *actual* Go StoreAgent integration can be
# linked to the no-JIT Unicorn TCI engine as iPhoneOS arm64 machine code.
# It never executes StoreAgent, fetches Apple assets, or accesses credentials.
set -euo pipefail

IPATOOL_COMMIT="4484b55d366e177ae6c89758c61588712c572fad"
ROOT="${RUNNER_TEMP:-/tmp}/ipadn-macpkg-tci-probe"
PROJECT_ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
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
    "fmt"
    "time"
    "unsafe"
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
//export iPadnMacTCIGoGuestProbe
func iPadnMacTCIGoGuestProbe(output *C.char, capacity C.int32_t) C.int32_t {
    report := func(msg string) {
        if output == nil || capacity < 2 || capacity > 4096 { return }
        bytes := unsafe.Slice((*byte)(unsafe.Pointer(output)), int(capacity))
        n := copy(bytes[:len(bytes)-1], msg)
        bytes[n] = 0
    }
    failed := func(stage string, err error, status C.int32_t) C.int32_t {
        report(fmt.Sprintf("%s: %v", stage, err))
        return status
    }
    e, err := unicorn.New(context.Background())
    if err != nil { return failed("创建 TCI", err, -1) }
    defer e.Close()
    if err = e.MemMap(0x100000, 0x2000); err != nil { return failed("映射代码", err, -2) }
    if err = e.MemMap(0x3ff000, 0x1000); err != nil { return failed("映射栈", err, -3) }
    // mov rax,0x1234 ; call 0x101000 ; add rax,7
    code := []byte{0x48,0xc7,0xc0,0x34,0x12,0,0,
                   0xe8,0xf4,0x0f,0,0, 0x48,0x83,0xc0,0x07}
    if err = e.MemWrite(0x100000, code); err != nil { return failed("写入指令", err, -4) }
    if err = e.MemWrite(0x101000, []byte{0xc3}); err != nil {
        return failed("写入模拟回调", err, -5)
    }
    if err = e.RegWrite(unicorn.RegRSP, 0x3fff00); err != nil {
        return failed("设置调用栈", err, -6)
    }
    callbacks := 0
    var callbackErr error
    hook, err := e.AddCodeHook(0x101000, 0x101000, func(address uint64, size uint32) {
        callbacks++
        if address != 0x101000 || size != 1 {
            callbackErr = fmt.Errorf("不符的回调位置 0x%x 长度 %d", address, size)
        } else if err := e.RegWrite(unicorn.RegRAX, 0x5678); err != nil {
            callbackErr = err
        }
    })
    if err != nil { return failed("安装 Go Hook", err, -7) }
    defer hook.Close()
    if err = e.StartBounded(0x100000, 0x100010, 500*time.Millisecond, 64); err != nil {
        return failed("Go 执行 TCI", err, -8)
    }
    if callbackErr != nil { return failed("Go 回调", callbackErr, -9) }
    rax, err := e.RegRead(unicorn.RegRAX)
    if err != nil { return failed("读取 RAX", err, -10) }
    if rax != 0x567f || callbacks != 1 {
        report(fmt.Sprintf("结果不匹配 RAX=0x%x，回调次数=%d", rax, callbacks))
        return -11
    }
    report(fmt.Sprintf("Go ↔ TCI 回调成功：RAX=0x%x，回调次数=%d", rax, callbacks))
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
