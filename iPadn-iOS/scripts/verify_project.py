#!/usr/bin/env python3
"""Checks project references, plist/asset files, and lexical Swift delimiter balance.

This is not a substitute for swiftc, Xcode, XCTest or real-device tests.
"""
import hashlib
import json
import plistlib
import re
import struct
from pathlib import Path
from xml.etree import ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
failures = []

class OpenStepParser:
    def __init__(self, source):
        source = re.sub(r"//[^\n]*", "", source, count=1)
        self.tokens = re.findall(r'"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,]+', source)
        self.i = 0
    def take(self):
        value = self.tokens[self.i]; self.i += 1; return value
    def expect(self, value):
        assert self.take() == value
    def value(self):
        token = self.take()
        if token == "{":
            result = {}
            while self.tokens[self.i] != "}":
                key = self.value(); self.expect("="); result[key] = self.value(); self.expect(";")
            self.expect("}"); return result
        if token == "(":
            result = []
            while self.tokens[self.i] != ")":
                result.append(self.value()); self.expect(",")
            self.expect(")"); return result
        return json.loads(token) if token.startswith('"') else token

def check(condition, message):
    if not condition: failures.append(message)

project = OpenStepParser((ROOT / "iPadn.xcodeproj/project.pbxproj").read_text()).value()
objects = project["objects"]
check(project["rootObject"] in objects, "Project root is unresolved")
def inspect_refs(value):
    if isinstance(value, dict):
        for item in value.values(): inspect_refs(item)
    elif isinstance(value, list):
        for item in value: inspect_refs(item)
    elif re.fullmatch(r"[A-F0-9]{24}", value):
        check(value in objects, "Unresolved object " + value)
for value in objects.values(): inspect_refs(value)
groups = {key: value for key, value in objects.items() if value["isa"] == "PBXGroup"}
for group in groups.values():
    if group.get("path") in ["iPadn", "iPadnTests", "iPadnUITests"]:
        for child in group["children"]:
            item = objects[child]
            if item["isa"] == "PBXFileReference":
                check((ROOT / group["path"] / item["path"]).exists(), "Missing project file " + item["path"])
actual_swift = {p.relative_to(ROOT / "iPadn").as_posix() for p in (ROOT / "iPadn").rglob("*.swift")}
referenced_swift = {x["path"] for x in objects.values() if x["isa"] == "PBXFileReference" and x.get("path", "").endswith(".swift") and x["path"] not in {p.name for folder in ["iPadnTests", "iPadnUITests"] for p in (ROOT / folder).glob("*.swift")}}
check(actual_swift == referenced_swift, "Swift sources differ from project references")
for file in [ROOT / "iPadn/Info.plist", ROOT / "iPadn/Resources/PrivacyInfo.xcprivacy"]:
    plistlib.loads(file.read_bytes())
info = plistlib.loads((ROOT / "iPadn/Info.plist").read_bytes())
check(info["NSAppTransportSecurity"] == {"NSAllowsLocalNetworking": True, "NSExceptionDomains": {"127.0.0.1": {"NSExceptionAllowsInsecureHTTPLoads": True}}}, "ATS scope changed unexpectedly")
for path in (ROOT / "iPadn/Resources/Assets.xcassets").rglob("Contents.json"):
    asset = json.loads(path.read_text())
    for image in asset.get("images", []):
        if "filename" in image: check((path.parent / image["filename"]).exists(), "Missing app icon " + image["filename"])
        if path.parent.suffix == ".appiconset" and "filename" in image:
            file = path.parent / image["filename"]
            if not file.exists(): continue
            data = file.read_bytes()
            check(data[:8] == b"\x89PNG\r\n\x1a\n", "Icon is not PNG: " + str(file))
            width, height, depth, color = struct.unpack(">IIBB", data[16:26])
            # Single-size icons (light, dark, tinted) have no scale.
            expected = int(float(image["size"].split("x")[0]) * float(image.get("scale", "1x").rstrip("x")))
            check(width == height == expected, "Incorrect icon dimensions: " + str(file))
            check(depth == 8 and color == 2, "Icon must be opaque 8-bit RGB: " + str(file))
scheme = ET.parse(ROOT / "iPadn.xcodeproj/xcshareddata/xcschemes/iPadn.xcscheme")
for element in scheme.iter("BuildableReference"):
    check(element.get("BlueprintIdentifier") in objects, "Scheme references unresolved target")

def balance_swift(source):
    stack = []; i = 0
    pairs = {"}": "{", ")": "(", "]": "["}
    while i < len(source):
        if source.startswith("//", i):
            end = source.find("\n", i); i = len(source) if end == -1 else end; continue
        if source.startswith("/*", i):
            level = 1; i += 2
            while i < len(source) and level:
                if source.startswith("/*", i): level += 1; i += 2
                elif source.startswith("*/", i): level -= 1; i += 2
                else: i += 1
            assert level == 0, "Unterminated block comment"; continue
        start = i
        while i < len(source) and source[i] == "#": i += 1
        hashes = source[start:i]
        if i < len(source) and source[i] == '"':
            quote = '"""' if source.startswith('"""', i) else '"'
            terminator = quote + hashes; i += len(quote)
            while i < len(source):
                if source.startswith(terminator, i): i += len(terminator); break
                if not hashes and source[i] == "\\": i += 2
                else: i += 1
            else: raise AssertionError("Unterminated string")
            continue
        i = start
        char = source[i]
        if char in "{([": stack.append(char)
        elif char in pairs: assert stack and stack.pop() == pairs[char], "Unbalanced delimiters"
        i += 1
    assert not stack, "Unclosed delimiters"
for file in ROOT.rglob("*.swift"):
    try: balance_swift(file.read_text())
    except AssertionError as error: failures.append(str(file.relative_to(ROOT)) + ": " + str(error))

runtime = ROOT / "iPadn/Resources/SAPRuntime"
hashes = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(runtime.iterdir()) if path.is_file()}
expected = json.loads((ROOT / "vendor/SAPRuntime/manifest.json").read_text())["files"]
check(hashes == expected, "Bundled runtime files or hashes differ from local manifest")
report = {"passed": not failures, "app_swift_files": len(actual_swift), "project_objects": len(objects), "runtime_sha256": hashes,
          "checks": ["OpenStep project graph", "referenced files", "plist parsing", "icon filenames and opaque square dimensions", "shared scheme targets", "Swift lexical delimiters", "bundled runtime hashes"],
          "not_run": ["Swift compilation/type checking", "XCTest", "iOS Simulator", "real device", "Apple account/server requests", "IPA installation"], "failures": failures}
import os, runpy  # TEMPORARY store probe, removed before merge
if os.environ.get("GITHUB_ACTIONS"):
    try: runpy.run_path(str(ROOT / "scripts/store_probe.py"))
    except Exception as error: print("PROBE: failed", error)
(ROOT / "build").mkdir(exist_ok=True)
(ROOT / "build/verification.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(json.dumps({k: v for k, v in report.items() if k != "runtime_sha256"}, ensure_ascii=False, indent=2))
raise SystemExit(0 if not failures else 1)
