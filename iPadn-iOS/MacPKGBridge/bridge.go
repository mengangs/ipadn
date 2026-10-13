// iPadn Mac App Store package bridge.
//
// Built by scripts/build_mac_pkg_bridge.sh inside a pinned ipatool checkout
// (it uses ipatool's internal StoreAgent runtime) as an iPhoneOS c-archive,
// linked together with the no-JIT Unicorn TCI interpreter. The app resolves
// these exports at runtime, so builds without the bridge simply report the
// feature as unavailable.
//
// The bridge does what the Mac App Store client does on a Mac for the account
// that was authorized for the download: open a StoreAgent session with the
// account-bound dpInfo and the same hardware ID that produced the request's
// kbsync, and decrypt the downloaded package stream. It never sees Apple ID
// credentials and never writes dpInfo anywhere.
package main

/*
#include <stdint.h>
*/
import "C"

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"sync"
	"sync/atomic"
	"unsafe"

	"github.com/majd/ipatool/v2/internal/sap/assets"
	"github.com/majd/ipatool/v2/internal/sap/machine"
)

const (
	stageIdle int32 = iota
	stageAssets
	stageStoreAgent
	stageDecrypting
)

var (
	operation     sync.Mutex
	cancelLock    sync.Mutex
	cancelCurrent context.CancelFunc
	processed     atomic.Int64
	stage         atomic.Int32
)

type countingWriter struct{ next io.Writer }

func (w countingWriter) Write(data []byte) (int, error) {
	n, err := w.next.Write(data)
	processed.Add(int64(n))
	return n, err
}

func writeMessage(output *C.char, capacity C.int32_t, text string) {
	if output == nil || capacity < 2 || capacity > 8192 {
		return
	}
	buffer := unsafe.Slice((*byte)(unsafe.Pointer(output)), int(capacity))
	n := copy(buffer[:len(buffer)-1], text)
	buffer[n] = 0
}

func failure(output *C.char, capacity C.int32_t, code C.int32_t, summary string, err error) C.int32_t {
	detail := ""
	if err != nil {
		detail = err.Error()
		if len(detail) > 240 {
			detail = detail[:240]
		}
		detail = "（" + detail + "）"
	}
	writeMessage(output, capacity, summary+detail)
	return code
}

// iPadnMacPKGDecrypt decrypts encryptedPath into decryptedPath. Returns 0 on
// success, 1 if cancelled, and a negative code with a message otherwise.
// Only one package is processed at a time; later calls wait.
//
//export iPadnMacPKGDecrypt
func iPadnMacPKGDecrypt(hardwareHex *C.char, dpInfo *C.uint8_t, dpInfoLength C.int32_t,
	encryptedPath, decryptedPath *C.char, message *C.char, capacity C.int32_t) C.int32_t {
	operation.Lock()
	defer operation.Unlock()

	ctx, cancel := context.WithCancel(context.Background())
	cancelLock.Lock()
	cancelCurrent = cancel
	cancelLock.Unlock()
	defer func() {
		cancelLock.Lock()
		cancelCurrent = nil
		cancelLock.Unlock()
		cancel()
		stage.Store(stageIdle)
	}()
	processed.Store(0)

	hardware, err := hex.DecodeString(C.GoString(hardwareHex))
	if err != nil || len(hardware) != 6 {
		return failure(message, capacity, -1, "设备标识无效，请重新获取 Mac 下载信息", nil)
	}
	if dpInfo == nil || dpInfoLength <= 0 || dpInfoLength > 1<<20 {
		return failure(message, capacity, -2, "缺少 Apple 下载授权信息，请重新获取 Mac 下载信息", nil)
	}
	info := C.GoBytes(unsafe.Pointer(dpInfo), C.int(dpInfoLength))
	source := C.GoString(encryptedPath)
	destination := C.GoString(decryptedPath)

	stage.Store(stageAssets)
	bundle, err := assets.Load(ctx)
	if err != nil {
		if ctx.Err() != nil {
			return 1
		}
		return failure(message, capacity, -3, "无法从 Apple 获取或校验 Mac 安装包处理组件，请检查网络后重试", err)
	}

	stage.Store(stageStoreAgent)
	agent, err := machine.OpenStoreAgent(ctx, bundle, hardware, info)
	if err != nil {
		if ctx.Err() != nil {
			return 1
		}
		return failure(message, capacity, -4, "Apple 安装包处理组件未能接受此下载授权，请重新获取 Mac 下载信息", err)
	}
	defer agent.Close()

	input, err := os.Open(source)
	if err != nil {
		return failure(message, capacity, -5, "无法读取已下载的 Mac 安装包", err)
	}
	defer input.Close()
	output, err := os.OpenFile(destination, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return failure(message, capacity, -6, "无法写入 Mac 安装包", err)
	}

	stage.Store(stageDecrypting)
	_, decryptErr := agent.Decrypt(ctx, countingWriter{next: output}, input)
	closeErr := output.Close()
	if decryptErr != nil || closeErr != nil {
		_ = os.Remove(destination)
		if ctx.Err() != nil || errors.Is(decryptErr, context.Canceled) {
			return 1
		}
		return failure(message, capacity, -7, "Mac 安装包处理失败", errors.Join(decryptErr, closeErr))
	}
	if err := agent.Close(); err != nil {
		_ = os.Remove(destination)
		return failure(message, capacity, -8, "Mac 安装包处理组件未能正常结束", err)
	}
	writeMessage(message, capacity, fmt.Sprintf("已处理 %d 字节", processed.Load()))
	return 0
}

// iPadnMacPKGStatus reports the current stage (0 idle, 1 loading Apple
// components, 2 starting StoreAgent, 3 decrypting) and bytes written.
//
//export iPadnMacPKGStatus
func iPadnMacPKGStatus(bytes *C.int64_t) C.int32_t {
	if bytes != nil {
		*bytes = C.int64_t(processed.Load())
	}
	return C.int32_t(stage.Load())
}

// iPadnMacPKGCancel cancels the package currently being processed, if any.
//
//export iPadnMacPKGCancel
func iPadnMacPKGCancel() {
	cancelLock.Lock()
	defer cancelLock.Unlock()
	if cancelCurrent != nil {
		cancelCurrent()
	}
}

func main() {}
