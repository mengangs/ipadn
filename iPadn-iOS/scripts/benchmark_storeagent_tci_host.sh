#!/bin/bash
# CI-host measurement of Apple's real StoreAgent / SAP runtime on Unicorn,
# comparing the pinned desktop JIT build against the no-JIT TCI interpreter
# that the iPhone diagnostics use. Runs on a macOS GitHub runner only.
#
# - Apple runtime files are fetched by ipatool from Apple's public software
#   update CDN and verified against ipatool's pinned SHA-256 digests. They stay
#   in the runner cache and are never uploaded as artifacts.
# - No Apple ID, password, token, dpInfo or package is used. kbsync is computed
#   locally for a synthetic DSID and only its length is printed.
set -euo pipefail

IPATOOL_COMMIT="4484b55d366e177ae6c89758c61588712c572fad"
TCI_COMMIT="53471ef9cf480fab094bf13db3e5d2f9e2c30dc5"
PROJECT_ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="${RUNNER_TEMP:-/tmp}/ipadn-storeagent-bench"
rm -rf "$ROOT"
mkdir -p "$ROOT/out"
cd "$ROOT"

git clone --no-checkout --filter=blob:none https://github.com/majd/ipatool.git ipatool
git -C ipatool checkout --detach "$IPATOOL_COMMIT"
test "$(git -C ipatool rev-parse HEAD)" = "$IPATOOL_COMMIT"
git clone --no-checkout --filter=blob:none https://github.com/Naville/unicorn.git unicorn-tci
git -C unicorn-tci checkout --detach "$TCI_COMMIT"
test "$(git -C unicorn-tci rev-parse HEAD)" = "$TCI_COMMIT"

# Host (macOS arm64) shared TCI library: same interpreter as the iPhone build.
cmake -S unicorn-tci -B tci-build -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON -DUNICORN_ARCH=x86 -DUNICORN_INTERPRETER=ON \
  -DUNICORN_BUILD_TESTS=OFF -DUNICORN_INSTALL=OFF
grep -Eq '^UNICORN_INTERPRETER:BOOL=ON$' tci-build/CMakeCache.txt
cmake --build tci-build --parallel 4
TCI_LIBRARY="$(find "$ROOT/tci-build" -maxdepth 1 -name 'libunicorn*.dylib' -type f | head -n 1)"
test -s "$TCI_LIBRARY"

# Two benchmark-only changes to the throwaway ipatool checkout:
# load an explicit Unicorn library, and lift the 1-minute guest-call bound so
# a slow interpreter is timed instead of aborted.
patch -d ipatool -p1 < "$PROJECT_ROOT/iPadn-iOS/scripts/ipatool-host-benchmark.patch"

mkdir -p ipatool/tools/ipadn-storeagent-bench
cat > ipatool/tools/ipadn-storeagent-bench/main.go <<'GOEOF'
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"runtime"
	"syscall"
	"time"

	"github.com/majd/ipatool/v2/internal/sap/assets"
	"github.com/majd/ipatool/v2/internal/sap/machine"
)

type stage struct {
	Name    string  `json:"name"`
	Seconds float64 `json:"seconds"`
	Detail  string  `json:"detail,omitempty"`
	Error   string  `json:"error,omitempty"`
}

type report struct {
	Engine    string  `json:"engine"`
	Platform  string  `json:"platform"`
	MaxRSSMiB float64 `json:"maxRSSMiB"`
	Stages    []stage `json:"stages"`
	Passed    bool    `json:"passed"`
}

func maxRSSMiB() float64 {
	var usage syscall.Rusage
	if syscall.Getrusage(syscall.RUSAGE_SELF, &usage) != nil {
		return 0
	}
	if runtime.GOOS == "darwin" {
		return float64(usage.Maxrss) / (1 << 20)
	}
	return float64(usage.Maxrss) / 1024
}

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: bench <engine-label> <report.json>")
		os.Exit(2)
	}
	result := report{Engine: os.Args[1], Platform: runtime.GOOS + "/" + runtime.GOARCH, Passed: true}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Minute)
	defer cancel()

	run := func(name string, body func() (string, error)) bool {
		start := time.Now()
		detail, err := body()
		item := stage{Name: name, Seconds: time.Since(start).Seconds(), Detail: detail}
		if err != nil {
			item.Error = err.Error()
			result.Passed = false
		}
		result.Stages = append(result.Stages, item)
		fmt.Printf("[%s] %-22s %8.2fs %s %s\n", result.Engine, name, item.Seconds, detail, item.Error)
		return err == nil
	}

	// Synthetic hardware ID and DSID: nothing here identifies a person or device.
	hardware := []byte{0x02, 0, 0, 0, 0, 1}
	var bundle assets.Bundle
	ok := run("apple-assets", func() (string, error) {
		var err error
		bundle, err = assets.Load(ctx)
		return fmt.Sprintf("CoreFP %d B", len(bundle.CoreFP)), err
	})
	ok = ok && run("storeagent-asset", func() (string, error) {
		image, err := assets.LoadStoreAgent(ctx)
		return fmt.Sprintf("%d B", len(image)), err
	})
	if ok {
		run("sap-open-initialize", func() (string, error) {
			guest, err := machine.Open(ctx, bundle)
			if err != nil {
				return "", err
			}
			defer guest.Close()
			session, err := guest.Initialize(hardware)
			if err != nil {
				return "", err
			}
			return "context created", guest.Teardown(session)
		})
		for attempt := 1; attempt <= 2; attempt++ {
			run(fmt.Sprintf("storeagent-kbsync-%d", attempt), func() (string, error) {
				blob, err := machine.GenerateKBSync(ctx, bundle, hardware, 1)
				return fmt.Sprintf("%d B", len(blob)), err
			})
		}
	}
	result.MaxRSSMiB = maxRSSMiB()
	data, _ := json.MarshalIndent(result, "", "  ")
	if err := os.WriteFile(os.Args[2], append(data, '\n'), 0o644); err != nil {
		panic(err)
	}
	if !result.Passed {
		os.Exit(1)
	}
}
GOEOF

(cd ipatool && go build -trimpath -o "$ROOT/out/storeagent-bench" ./tools/ipadn-storeagent-bench)

# JIT first: it downloads and caches the verified Apple files and the pinned
# Unicorn wheel; the TCI run then reuses the same cached Apple files.
JIT_STATUS=0
"$ROOT/out/storeagent-bench" jit "$ROOT/out/jit.json" || JIT_STATUS=$?
TCI_STATUS=0
IPADN_UNICORN_LIBRARY="$TCI_LIBRARY" "$ROOT/out/storeagent-bench" tci "$ROOT/out/tci.json" || TCI_STATUS=$?

python3 - "$ROOT/out/jit.json" "$ROOT/out/tci.json" <<'PY'
import json, os, sys
reports = []
for path in sys.argv[1:]:
    try:
        reports.append(json.load(open(path)))
    except (OSError, ValueError):
        reports.append(None)
jit, tci = reports
names = []
for report in reports:
    for item in (report or {}).get("stages", []):
        if item["name"] not in names:
            names.append(item["name"])
def cell(report, name):
    for item in (report or {}).get("stages", []):
        if item["name"] == name:
            return item
    return None
lines = ["## StoreAgent on Unicorn: JIT vs no-JIT TCI (CI host)", "",
         "| Stage | JIT | TCI | TCI / JIT |", "|---|---|---|---|"]
for name in names:
    a, b = cell(jit, name), cell(tci, name)
    fmt = lambda x: "—" if x is None else ("FAILED: " + x["error"][:120] if x.get("error") else "%.2fs" % x["seconds"])
    ratio = "—"
    if a and b and not a.get("error") and not b.get("error") and a["seconds"] > 0.01:
        ratio = "%.1fx" % (b["seconds"] / a["seconds"])
    lines.append("| %s | %s | %s | %s |" % (name, fmt(a), fmt(b), ratio))
lines += ["", "Peak RSS: JIT %.0f MiB, TCI %.0f MiB." % ((jit or {}).get("maxRSSMiB", 0), (tci or {}).get("maxRSSMiB", 0)),
          "", "Synthetic hardware ID and DSID; no Apple ID, dpInfo or package involved. Apple files are cached on the runner only.",
          "Package decryption cost is not measured here: it needs an account-bound dpInfo."]
text = "\n".join(lines) + "\n"
print(text)
summary = os.environ.get("GITHUB_STEP_SUMMARY")
if summary:
    open(summary, "a").write(text)
PY

test "$JIT_STATUS" -eq 0 || { echo "JIT baseline failed; CI environment or Apple asset download problem." >&2; exit 1; }
test "$TCI_STATUS" -eq 0 || { echo "Real StoreAgent did not complete on the no-JIT TCI interpreter." >&2; exit 1; }
echo "Real StoreAgent kbsync completed on both JIT and no-JIT TCI Unicorn."
