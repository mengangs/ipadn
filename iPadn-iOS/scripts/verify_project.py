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
    if group.get("path") in ["iPadn", "iPadnTests", "iPadnUITests", "iPadnLiveActivity"]:
        for child in group["children"]:
            item = objects[child]
            if item["isa"] == "PBXFileReference":
                check((ROOT / group["path"] / item["path"]).exists(), "Missing project file " + item["path"])
actual_swift = {p.relative_to(ROOT / "iPadn").as_posix() for p in (ROOT / "iPadn").rglob("*.swift")}
referenced_swift = {x["path"] for x in objects.values() if x["isa"] == "PBXFileReference" and x.get("path", "").endswith(".swift") and x["path"] not in {p.name for folder in ["iPadnTests", "iPadnUITests", "iPadnLiveActivity"] for p in (ROOT / folder).glob("*.swift")}}
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

# Localization: Chinese source strings keyed by their own text, every shipped
# language translated in the same catalogs. A language missing a value would show
# the development language (English) for that string instead.
LANGUAGES = ["zh-Hans", "en", "zh-Hant", "ja", "ko", "ru", "es", "fr", "de", "pt-BR", "ar"]
PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|u|@|lf|f|%)|\$\{[A-Za-z]+\}")
catalogs = {}
for name, file in [("Localizable", ROOT / "iPadn/Resources/Localizable.xcstrings"),
                   ("InfoPlist", ROOT / "iPadn/Resources/InfoPlist.xcstrings"),
                   ("AppShortcuts", ROOT / "iPadn/Resources/AppShortcuts.xcstrings"),
                   ("LiveActivity", ROOT / "iPadnLiveActivity/Localizable.xcstrings")]:
    check(file.exists(), "Missing string catalog " + name)
    if not file.exists(): continue
    catalog = json.loads(file.read_text())
    catalogs[name] = catalog
    check(catalog.get("sourceLanguage") == "zh-Hans", name + ".xcstrings source language must be zh-Hans")
    check(isinstance(catalog.get("strings"), dict), name + ".xcstrings has no strings")
    for key, entry in catalog.get("strings", {}).items():
        # An empty key is a placeholder label, never shown as text.
        if key == "": continue
        localizations = entry.get("localizations", {})
        for language in LANGUAGES:
            check(language in localizations, name + ".xcstrings: no " + language + " for " + repr(key))
        expected = sorted(PLACEHOLDER.findall(key)) if name != "InfoPlist" else None
        for language, unit in localizations.items():
            values = []
            if "stringUnit" in unit: values.append(unit["stringUnit"].get("value", ""))
            for form in unit.get("variations", {}).get("plural", {}).values():
                values.append(form["stringUnit"].get("value", ""))
            check(values and all(v != "" for v in values), name + ".xcstrings: empty value for " + repr(key) + " (" + language + ")")
            if language not in ("zh-Hans", "zh-Hant", "ja"):
                check(not any("\u4e00" <= c <= "\u9fff" for v in values for c in v), name + ".xcstrings: Chinese left in " + language + " for " + repr(key))
            if expected is not None:
                for v in values:
                    check(sorted(PLACEHOLDER.findall(v)) == expected, name + ".xcstrings: placeholders differ in " + language + " for " + repr(key))
        if "variations" in localizations.get("en", {}):
            check("%lld" in key or "%d" in key or "%@" in key, name + ".xcstrings: plural without a number in " + repr(key))
target_project = objects[project["rootObject"]]
check(target_project.get("developmentRegion") == "en", "The development language must stay en so other languages see English")
check("zh-Hans" in (target_project.get("knownRegions") or []), "knownRegions must include zh-Hans")
for language in LANGUAGES:
    check(language in (target_project.get("knownRegions") or []), "knownRegions must include " + language)
resource_paths = set()
for phase in objects.values():
    if phase.get("isa") != "PBXResourcesBuildPhase": continue
    for child in phase.get("files", []):
        reference = objects.get(objects.get(child, {}).get("fileRef"), {})
        if reference.get("path"): resource_paths.add(reference["path"])
        if reference.get("isa") == "PBXVariantGroup" and reference.get("name") == "AppShortcuts.strings":
            resource_paths.add("Resources/AppShortcuts.strings")
for name in ["Localizable.xcstrings", "InfoPlist.xcstrings", "AppShortcuts.strings"]:
    check("Resources/" + name in resource_paths, name + " is not in the app's resources")
for language in LANGUAGES:
    shortcut_strings = ROOT / f"iPadn/Resources/{language}.lproj/AppShortcuts.strings"
    expected_lines = []
    for key, entry in catalogs.get("AppShortcuts", {}).get("strings", {}).items():
        value = entry["localizations"][language]["stringUnit"]["value"]
        expected_lines.append(f"{json.dumps(key, ensure_ascii=False)} = {json.dumps(value, ensure_ascii=False)};")
    check(shortcut_strings.is_file() and shortcut_strings.read_text(encoding="utf-8").splitlines() == expected_lines,
          "AppShortcuts.strings differs from the catalog for " + language)
check("Localizable.xcstrings" in resource_paths, "The Live Activity catalog is not in the extension's resources")
check(catalogs.get("InfoPlist", {}).get("strings", {}).get("NSLocalNetworkUsageDescription", {}).get("localizations", {}).get("en") is not None,
      "InfoPlist.xcstrings must translate NSLocalNetworkUsageDescription")

runtime = ROOT / "iPadn/Resources/SAPRuntime"
hashes = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(runtime.iterdir()) if path.is_file()}
expected = json.loads((ROOT / "vendor/SAPRuntime/manifest.json").read_text())["files"]
check(hashes == expected, "Bundled runtime files or hashes differ from local manifest")
report = {"passed": not failures, "app_swift_files": len(actual_swift), "project_objects": len(objects), "runtime_sha256": hashes,
          "checks": ["OpenStep project graph", "referenced files", "plist parsing", "icon filenames and opaque square dimensions", "shared scheme targets", "Swift lexical delimiters", "bundled runtime hashes", "string catalogs (zh-Hans, en, zh-Hant, ja, ko, ru, es, fr, de, pt-BR, ar; placeholders)"],
          "not_run": ["Swift compilation/type checking", "XCTest", "iOS Simulator", "real device", "Apple account/server requests", "IPA installation"], "failures": failures}
(ROOT / "build").mkdir(exist_ok=True)
(ROOT / "build/verification.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(json.dumps({k: v for k, v in report.items() if k != "runtime_sha256"}, ensure_ascii=False, indent=2))
raise SystemExit(0 if not failures else 1)
