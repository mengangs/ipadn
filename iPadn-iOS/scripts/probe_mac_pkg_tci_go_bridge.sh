#!/bin/bash
# Build-only check that ipatool's *actual* Go StoreAgent integration can be
# linked to the no-JIT Unicorn TCI engine as iPhoneOS arm64 machine code.
# It never executes StoreAgent, fetches Apple assets, or accesses credentials.
set -euo pipefail

IPATOOL_COMMIT="4484b55d366e177ae6c89758c61588712c572fad"
ROOT="${RUNNER_TEMP:-/tmp}/ipadn-macpkg-tci-probe"
PROJECT_ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
MACOS_SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun --sdk iphoneos --find clang)"
LIBRARY="$ROOT/build/libunicorn.a"
test -s "$LIBRARY" || { echo 'Build the pinned TCI library first.' >&2; exit 1; }

cd "$ROOT"
git clone --no-checkout --filter=blob:none https://github.com/majd/ipatool.git ipatool
git -C ipatool checkout --detach "$IPATOOL_COMMIT"
test "$(git -C ipatool rev-parse HEAD)" = "$IPATOOL_COMMIT"

# Generate a tiny independently authored macOS x86-64 Mach-O dylib.
# It contains no Apple private framework, license, installer or DRM data.
cat > "$ROOT/synthetic_storeagent.s" <<'ASM'
.text
.globl _ipadn_synthetic_answer
.p2align 4
_ipadn_synthetic_answer:
    movq $0x1234, %rax
    addq $7, %rax
    retq
ASM
env SDKROOT="$MACOS_SDKROOT" "$CC" -target x86_64-apple-macos11 \
  -isysroot "$MACOS_SDKROOT" -c \
  "$ROOT/synthetic_storeagent.s" -o "$ROOT/synthetic_storeagent.o"
env SDKROOT="$MACOS_SDKROOT" "$CC" -target x86_64-apple-macos11 \
  -isysroot "$MACOS_SDKROOT" -dynamiclib \
  -Wl,-install_name,@rpath/libipadn_synthetic.dylib \
  -o "$ROOT/synthetic_storeagent.dylib" "$ROOT/synthetic_storeagent.o"
test -s "$ROOT/synthetic_storeagent.dylib"
xcrun file "$ROOT/synthetic_storeagent.dylib"
mkdir -p ipatool/tools/ios-tci-link
cp "$ROOT/synthetic_storeagent.dylib" ipatool/tools/ios-tci-link/fixture.dylib

# A second ORIGINAL x86-64 dylib imports the provider's exported function via
# its non-lazy GOT entry. Exercises ipatool's Mach-O BIND_TYPE_POINTER resolver.
cp "$ROOT/synthetic_storeagent.dylib" "$ROOT/libipadn_synthetic.dylib"
cat > "$ROOT/synthetic_consumer.s" <<'CONSUMER_ASM'
.text
.globl _ipadn_synthetic_consumer
.globl _ipadn_synthetic_consumer_stop
.p2align 4
_ipadn_synthetic_consumer:
    movq _ipadn_synthetic_answer@GOTPCREL(%rip), %r11
    callq *%r11
    addq $9, %rax
_ipadn_synthetic_consumer_stop:
    retq
CONSUMER_ASM
env SDKROOT="$MACOS_SDKROOT" "$CC" -target x86_64-apple-macos11 \
  -isysroot "$MACOS_SDKROOT" -c "$ROOT/synthetic_consumer.s" \
  -o "$ROOT/synthetic_consumer.o"
env SDKROOT="$MACOS_SDKROOT" "$CC" -target x86_64-apple-macos11 \
  -isysroot "$MACOS_SDKROOT" -dynamiclib \
  -Wl,-install_name,@rpath/libipadn_consumer.dylib \
  "$ROOT/synthetic_consumer.o" -L"$ROOT" -lipadn_synthetic \
  -o "$ROOT/synthetic_consumer.dylib"
test -s "$ROOT/synthetic_consumer.dylib"
xcrun file "$ROOT/synthetic_consumer.dylib"
xcrun nm -u "$ROOT/synthetic_consumer.dylib" | grep '_ipadn_synthetic_answer'
cp "$ROOT/synthetic_consumer.dylib" ipatool/tools/ios-tci-link/consumer.dylib

# Before compiling for iPhone, exercise ipatool's real Go Mach-O parser on
# this fixture on the CI host. This catches malformed symbol tables, missing
# x86_64 slices, and relocation mistakes without installing any app.
mkdir -p ipatool/tools/ios-tci-fixture-check
cat > ipatool/tools/ios-tci-fixture-check/main.go <<'FIXTURE_GO'
package main

import (
    "errors"
    "fmt"
    "os"

    "github.com/majd/ipatool/v2/internal/sap/machimage"
)

func main() {
    data, err := os.ReadFile("tools/ios-tci-link/fixture.dylib")
    if err != nil { panic(err) }
    img, err := machimage.Open("ipadn-ci-fixture", data)
    if err != nil { panic(fmt.Errorf("open synthetic Mach-O: %w", err)) }
    const base uint64 = 0x00001000c0000000
    address, err := img.Export("_ipadn_synthetic_answer", base)
    if err != nil { panic(fmt.Errorf("resolve synthetic answer: %w", err)) }
    if address < base || address > base+(8<<20) {
        panic(fmt.Errorf("unexpected Mach-O symbol 0x%x", address))
    }
    if err := img.Relocate(base, func(symbol string) (uint64, error) {
        return 0, errors.New("unexpected synthetic dependency: " + symbol)
    }); err != nil {
        panic(fmt.Errorf("relocate synthetic fixture: %w", err))
    }
    consumerBytes, err := os.ReadFile("tools/ios-tci-link/consumer.dylib")
    if err != nil { panic(err) }
    consumer, err := machimage.Open("ipadn-ci-consumer", consumerBytes)
    if err != nil { panic(fmt.Errorf("open synthetic consumer: %w", err)) }
    const consumerBase uint64 = 0x00001000e0000000
    entry, err := consumer.Export("_ipadn_synthetic_consumer", consumerBase)
    if err != nil { panic(fmt.Errorf("export synthetic consumer: %w", err)) }
    stop, err := consumer.Export("_ipadn_synthetic_consumer_stop", consumerBase)
    if err != nil { panic(fmt.Errorf("export synthetic consumer stop: %w", err)) }
    if entry >= stop || stop-entry > 128 {
        panic(fmt.Errorf("invalid imported call range: start=0x%x stop=0x%x", entry, stop))
    }
    imports := 0
    if err := consumer.Relocate(consumerBase, func(symbol string) (uint64, error) {
        if symbol != "_ipadn_synthetic_answer" {
            return 0, fmt.Errorf("unexpected consumer import: %s", symbol)
        }
        imports++
        return address, nil
    }); err != nil { panic(fmt.Errorf("bind synthetic consumer: %w", err)) }
    if imports != 1 { panic(fmt.Errorf("expected one cross-image binding; got %d", imports)) }
    fmt.Printf("PASS: Go Mach-O external binding: provider 0x%x, consumer start 0x%x, stop 0x%x, imports %d\\n", address, entry, stop, imports)
}
FIXTURE_GO
(cd ipatool && go run ./tools/ios-tci-fixture-check)
cat > ipatool/tools/ios-tci-link/main.go <<'GOEOF'
package main

/*
#include <stdint.h>
*/
import "C"
import (
    "context"
    _ "embed"
    "fmt"
    "time"
    "unsafe"
    "github.com/majd/ipatool/v2/internal/sap/assets"
    "github.com/majd/ipatool/v2/internal/sap/machine"
    "github.com/majd/ipatool/v2/internal/sap/machimage"
    "github.com/majd/ipatool/v2/internal/sap/unicorn"
)

//go:embed fixture.dylib
var syntheticMachO []byte

//go:embed consumer.dylib
var syntheticMachOConsumer []byte

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
//export iPadnMacTCIMachOLoadProbe
func iPadnMacTCIMachOLoadProbe(output *C.char, capacity C.int32_t) C.int32_t {
    report := func(msg string) {
        if output == nil || capacity < 2 || capacity > 4096 { return }
        dst := unsafe.Slice((*byte)(unsafe.Pointer(output)), int(capacity))
        n := copy(dst[:len(dst)-1], msg)
        dst[n] = 0
    }
    fail := func(stage string, err error, code C.int32_t) C.int32_t {
        report(fmt.Sprintf("%s：%v", stage, err))
        return code
    }
    // Read/relocate/load an original synthetic Mach-O fixture using the exact
    // Go loader ipatool uses for StoreAgent. Guest execution remains no-JIT.
    image, err := machimage.Open("ipadn-synthetic", syntheticMachO)
    if err != nil { return fail("读取模拟 x86 Mach-O", err, -30) }
    const base uint64 = 0x00001000c0000000
    address, err := image.Export("_ipadn_synthetic_answer", base)
    if err != nil { return fail("查询模拟符号", err, -31) }
    if err = image.Relocate(base, func(name string) (uint64, error) {
        return 0, fmt.Errorf("模拟代码出现意外外部依赖 %s", name)
    }); err != nil { return fail("重定位模拟 Mach-O", err, -32) }
    engine, err := unicorn.New(context.Background())
    if err != nil { return fail("创建 TCI 引擎", err, -33) }
    defer engine.Close()
    if err = image.Load(engine); err != nil {
        return fail("装载已重定位 Mach-O", err, -34)
    }
    // The synthetic code is exactly 7-byte MOV, 4-byte ADD and one-byte RET.
    // Stop at RET (not after RET) to avoid requiring an external call frame.
    if err = engine.StartBounded(address, address+11, 500*time.Millisecond, 64); err != nil {
        return fail("解释执行已加载的 x86 Mach-O", err, -35)
    }
    rax, err := engine.RegRead(unicorn.RegRAX)
    if err != nil { return fail("读取寄存器", err, -36) }
    if rax != 0x123b {
        report(fmt.Sprintf("模拟 Mach-O 执行结果不符 RAX=0x%x，预期 0x123b", rax))
        return -37
    }
    report(fmt.Sprintf("真实 Go Mach-O 加载器 / 高虚拟地址 / TCI 模拟执行成功，RAX=0x%x；未加载 Apple StoreAgent", rax))
    return 0
}

//export iPadnMacTCIGuestMemoryProbe
func iPadnMacTCIGuestMemoryProbe(output *C.char, capacity C.int32_t) C.int32_t {
    report := func(msg string) {
        if output == nil || capacity < 2 || capacity > 4096 { return }
        dst := unsafe.Slice((*byte)(unsafe.Pointer(output)), int(capacity))
        n := copy(dst[:len(dst)-1], msg)
        dst[n] = 0
    }
    engine, err := unicorn.New(context.Background())
    if err != nil {
        report(fmt.Sprintf("创建无 JIT 引擎失败: %v", err))
        return -20
    }
    defer engine.Close()
    // Addresses/sizes from ipatool's Machine runtime. In this isolated test,
    // there is no Apple code, authentication, decryption or package data.
    regions := []struct {
        name string
        address uint64
        size uint64
    }{
        {"scratch", 0x0000300000000000, 32 << 20},
        {"heap", 0x0000400000000000, 64 << 20},
        {"stack", 0x0000500000000000, 8 << 20},
    }
    const page = 4096
    var test [page]byte
    for i := range test { test[i] = byte(i*31 + 7) }
    for index, region := range regions {
        if err = engine.MemMap(region.address, region.size); err != nil {
            report(fmt.Sprintf("第 %d 个区域 %s (%d MiB) 映射失败: %v",
                index+1, region.name, region.size>>20, err))
            return -21
        }
        for _, address := range []uint64{region.address, region.address+region.size-page} {
            if err = engine.MemWrite(address, test[:]); err != nil {
                report(fmt.Sprintf("%s 写入 0x%x 失败: %v", region.name, address, err))
                return -22
            }
            var readback [page]byte
            if err = engine.MemReadInto(readback[:], address); err != nil {
                report(fmt.Sprintf("%s 读取 0x%x 失败: %v", region.name, address, err))
                return -23
            }
            if readback != test {
                report(fmt.Sprintf("%s 在 0x%x 数据不一致", region.name, address))
                return -24
            }
        }
    }
    report("TCI 的 scratch 32 MiB + heap 64 MiB + stack 8 MiB 映射、首末页读写均通过（合计 104 MiB 模拟内存）；未加载 StoreAgent")
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
# Separate, user-triggered executable for testing the Go/c-archive/TCI path.
APP="$ROOT/out/MacPKGGoTCIProbe.app"
mkdir -p "$APP" "$ROOT/out/go-package/Payload"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.ipadn.macpkg-go-tci-probe</string>
<key>CFBundleExecutable</key><string>MacPKGGoTCIProbe</string>
<key>CFBundleDisplayName</key><string>Mac PKG Go+TCI测试</string>
<key>CFBundleName</key><string>Mac PKG Go TCI Probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleShortVersionString</key><string>0.9</string>
<key>CFBundleVersion</key><string>9</string>
<key>LSRequiresIPhoneOS</key><true/>
<key>MinimumOSVersion</key><string>15.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
"$CC" -target arm64-apple-ios15.0 -isysroot "$SDKROOT" -fobjc-arc \
  "$PROJECT_ROOT/iPadn-iOS/scripts/mac_pkg_tci_go_probe.m" \
  "$ROOT/out/libMacPKGTCIStoreAgentBridge.a" \
  -Wl,-force_load,"$LIBRARY" -Wl,-export_dynamic \
  -framework UIKit -framework Foundation -framework Security -framework CoreFoundation \
  -lresolv -liconv -lz -lc++ -o "$APP/MacPKGGoTCIProbe"
cp "$ROOT/source/COPYING" "$APP/GPL-2.0.txt"
cp "$ROOT/ipatool/LICENSE" "$APP/ipatool-MIT.txt"
cat > "$APP/Source.txt" <<TXT
Independent Go and no-JIT TCI diagnostic.
TCI GPL-2.0: https://github.com/Naville/unicorn/tree/53471ef9cf480fab094bf13db3e5d2f9e2c30dc5
ipatool MIT: https://github.com/majd/ipatool/tree/$IPATOOL_COMMIT
Does not execute StoreAgent, download Apple assets or use Apple credentials.
TXT
plutil -lint "$APP/Info.plist"
xcrun vtool -show-build "$APP/MacPKGGoTCIProbe"
cp -R "$APP" "$ROOT/out/go-package/Payload/"
(cd "$ROOT/out/go-package" &&
  /usr/bin/zip -qr -X "$ROOT/out/MacPKGGoTCIProbe-unsigned.ipa" Payload)
test -s "$ROOT/out/MacPKGGoTCIProbe-unsigned.ipa"
du -h "$ROOT/out/MacPKGGoTCIProbe-unsigned.ipa"
echo "Go ↔ no-JIT TCI v0.9 iPhone diagnostic IPA built but NOT run by CI."
echo "NO StoreAgent initialization, Apple asset retrieval, authorization, Mac PKG download or decryption performed."
