#!/usr/bin/env python3
"""Writes altstore-source.json from the published GitHub releases.

AltStore, SideStore, Feather and similar signing tools read this file to
list iPadn and offer its updates. Run after a release is published:

    python3 iPadn-iOS/scripts/generate_altstore_source.py

Uses GH_TOKEN or GITHUB_TOKEN when set (CI), else anonymous requests.
"""
import json
import os
import re
import sys
import urllib.request
from pathlib import Path

REPO = "mengangs/ipadn"
RAW = "https://raw.githubusercontent.com/" + REPO + "/main/"
ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "altstore-source.json"
KEEP = 10
DESCRIPTION = (
    "Search, download and install the apps you own on iPhone and iPad: older versions, "
    "apps removed from sale, regional price comparison and native install. Free, open source, 11 languages.\n\n"
    "在 iPhone 和 iPad 上搜索、下载、安装你拥有的 App：历史版本、已下架应用、多地区比价与原生安装。永久免费开源。"
)
SCREENSHOTS = ["01-search", "02-detail", "03-versions", "04-prices", "05-downloads", "06-purchased", "07-native-install"]


def fetch(url):
    request = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json", "User-Agent": "iPadn-source"})
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token and url.startswith("https://api.github.com/"):
        request.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read()


def notes(body):
    """Release notes without the build's verification line."""
    lines = [line for line in (body or "").replace("\r\n", "\n").split("\n") if not line.startswith("验证：")]
    return "\n".join(lines).strip()


def version_entry(release):
    """One source entry for a published release, or None when it has no package."""
    tag = release.get("tag_name", "")
    if release.get("draft") or release.get("prerelease") or not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        return None
    assets = {asset["name"]: asset for asset in release.get("assets", [])}
    # The standard package (with the extension); the lite one is for App ID-limited signing.
    package = next((asset for name, asset in assets.items() if name.endswith("-unsigned.ipa") and "-lite-" not in name), None)
    if package is None:
        return None
    version = tag[1:]
    build, minimum = version, "17.0"
    info = assets.get("build-info.json")
    if info is not None:
        try:
            details = json.loads(fetch(info["browser_download_url"]))
            build = str(details.get("build") or build)
            minimum = str(details.get("minimum_ios") or minimum)
        except Exception as error:  # A missing detail is not worth failing a release for.
            print("build-info for " + tag + ": " + str(error), file=sys.stderr)
    return {
        "version": version,
        "buildVersion": build,
        "date": release["published_at"],
        "localizedDescription": notes(release.get("body")),
        "downloadURL": package["browser_download_url"],
        "size": package["size"],
        "minOSVersion": minimum,
    }


def source(releases):
    versions = [entry for entry in (version_entry(release) for release in releases) if entry]
    versions.sort(key=lambda entry: [int(part) for part in entry["version"].split(".")], reverse=True)
    versions = versions[:KEEP]
    if not versions:
        raise SystemExit("No published release with a package")
    latest = versions[0]
    return {
        "name": "iPadn",
        "identifier": "app.local.iPadn.source",
        "subtitle": "Search, download and install the apps you own",
        "description": DESCRIPTION,
        "iconURL": RAW + "docs/images/icon.png",
        "website": "https://github.com/" + REPO,
        "tintColor": "#111111",
        "featuredApps": ["app.local.iPadn"],
        "apps": [{
            "name": "iPadn",
            "bundleIdentifier": "app.local.iPadn",
            "developerName": "mengangs",
            "subtitle": "Search, download and install the apps you own",
            "localizedDescription": DESCRIPTION,
            "iconURL": RAW + "docs/images/icon.png",
            "tintColor": "#111111",
            "category": "utilities",
            "screenshots": [RAW + "docs/images/en/" + name + ".jpg" for name in SCREENSHOTS],
            "versions": versions,
            "appPermissions": {
                "entitlements": [],
                "privacy": {
                    "NSLocalNetworkUsageDescription": "Loads signing resources and serves installation packages over this device's loopback address, and finds this device's installation service."
                },
            },
            # Fields older clients read instead of "versions".
            "version": latest["version"],
            "versionDate": latest["date"],
            "versionDescription": latest["localizedDescription"],
            "downloadURL": latest["downloadURL"],
            "size": latest["size"],
        }],
        "news": [],
    }


def main():
    releases = json.loads(fetch("https://api.github.com/repos/" + REPO + "/releases?per_page=30"))
    text = json.dumps(source(releases), ensure_ascii=False, indent=2) + "\n"
    OUTPUT.write_text(text, encoding="utf-8")
    print("Wrote " + str(OUTPUT.relative_to(ROOT)) + " with " + str(text.count('"buildVersion"')) + " versions")


if __name__ == "__main__":
    main()
