"""Read-only IPA audit and InstallationProxy options for the installation experiment.

Protocol references (not a re-signing or DRM implementation):
https://github.com/libimobiledevice/ideviceinstaller/blob/master/src/ideviceinstaller.c
https://github.com/jkcoxson/idevice/blob/master/idevice/src/utils/installation/mod.rs
"""
from __future__ import annotations

import hashlib
import plistlib
import re
import stat
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


class ProbeError(Exception):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_path(value: str) -> bool:
    return (bool(value) and "\\" not in value and not value.startswith("/")
            and all(part not in ("", ".", "..") and ":" not in part
                    for part in value.rstrip("/").split("/")))


def plist_dict(data: bytes) -> dict[str, Any]:
    try:
        value = plistlib.loads(data)
    except Exception as error:
        raise ProbeError("Invalid property list") from error
    if not isinstance(value, dict):
        raise ProbeError("Expected a property-list dictionary")
    return value


def text(value: Any) -> str:
    return value if isinstance(value, str) else ""


def redacted(value: Any) -> str:
    value = str(value)
    value = re.sub(r"-----BEGIN [^-]+-----.*?-----END [^-]+-----", "<key>", value, flags=re.DOTALL)
    value = re.sub(r"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}", "<account>", value)
    value = re.sub(r"(?i)\b(?:DSID|DSPersonID|AppleID|PurchaserID|DownloaderID)\s*[:=]\s*[^\s,;]+", "account=<redacted>", value)
    value = re.sub(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{16}\b|\b[0-9a-fA-F]{40}\b", "<device>", value)
    value = re.sub(r"[A-Za-z0-9+/=]{80,}", "<data>", value)
    return value[:1200]


def metadata_summary(metadata: dict[str, Any]) -> dict[str, Any]:
    download = metadata.get("com.apple.iTunesStore.downloadInfo")
    account = download.get("accountInfo", {}) if isinstance(download, dict) else {}
    if not isinstance(account, dict):
        account = {}
    item = metadata.get("itemId")
    return {
        "item_id": str(item) if isinstance(item, (int, str)) and str(item).isdigit() else None,
        "bundle_id": text(metadata.get("softwareVersionBundleId")),
        "display_version": text(metadata.get("bundleShortVersionString")),
        "has_download_info": isinstance(download, dict),
        "has_account_association": bool(account.get("AppleID") or account.get("DSPersonID")),
        "has_enterprise_install_url": any(
            key.lower() == "enterpriseinstallurl" for key in metadata
        ),
    }


@dataclass(frozen=True)
class AuditedIPA:
    path: Path
    sha256: str
    bundle_id: str
    executable: str
    display_version: str
    build_version: str
    metadata: bytes = field(repr=False)
    main_sinf: bytes = field(repr=False)
    sinf_paths: tuple[str, ...]
    embedded_profile: bool

    def options(self, mode: str = "store") -> dict[str, Any]:
        if mode not in ("store", "embedded"):
            raise ProbeError("Unknown options mode")
        result: dict[str, Any] = {"CFBundleIdentifier": self.bundle_id}
        if mode == "store":
            # These are plist DATA values, not parsed dictionaries/base64 strings.
            # Preserve the exact bytes from the IPA. Never set PackageType=Developer.
            result.update(iTunesMetadata=self.metadata, ApplicationSINF=self.main_sinf)
        return result

    def summary(self, mode: str = "store") -> dict[str, Any]:
        return {
            "sha256": self.sha256, "bundle_id": self.bundle_id,
            "display_version": self.display_version, "build_version": self.build_version,
            "embedded_profile": self.embedded_profile,
            "metadata": metadata_summary(plist_dict(self.metadata)),
            "metadata_sha256": hashlib.sha256(self.metadata).hexdigest(),
            "main_sinf_sha256": hashlib.sha256(self.main_sinf).hexdigest(),
            "sinf_paths": list(self.sinf_paths),
            "client_option_keys": sorted(self.options(mode)),
            "signature_verification": "not_performed; input bytes are preserved",
            "authorization_validation": "not_performed; material presence only",
        }


def inspect_ipa(path: Path) -> AuditedIPA:
    path = path.resolve(strict=True)
    if not path.is_file() or path.suffix.lower() != ".ipa":
        raise ProbeError("A regular .ipa file is required")
    before = sha256_file(path)
    try:
        with zipfile.ZipFile(path) as archive:
            entries: dict[str, zipfile.ZipInfo] = {}
            for entry in archive.infolist():
                name = entry.filename
                if not safe_path(name) or name in entries:
                    raise ProbeError("Unsafe or duplicate ZIP entry")
                entries[name] = entry

            def read(name: str, maximum: int = 2 * 1024 * 1024) -> bytes:
                entry = entries.get(name)
                if entry is None or entry.is_dir() or stat.S_ISLNK(entry.external_attr >> 16):
                    raise ProbeError("Required regular IPA entry is missing: " + name)
                if entry.file_size > maximum:
                    raise ProbeError("IPA metadata exceeds inspection limit")
                return archive.read(entry)  # ZipFile checks the entry CRC.

            infos = [name for name in entries if len(name.split("/")) == 3
                     and name.startswith("Payload/") and name.split("/")[1].endswith(".app")
                     and name.endswith("/Info.plist")]
            if len(infos) != 1:
                raise ProbeError("Exactly one main application is required")
            root = infos[0].rsplit("/", 1)[0] + "/"
            info = plist_dict(read(infos[0]))
            bundle = text(info.get("CFBundleIdentifier"))
            executable = text(info.get("CFBundleExecutable"))
            version = text(info.get("CFBundleShortVersionString"))
            build = text(info.get("CFBundleVersion"))
            if not bundle or not version or not build or not executable or "/" in executable or "\\" in executable:
                raise ProbeError("Application identity, display version or build version is missing")
            binary = entries.get(root + executable)
            if binary is None or binary.is_dir() or not binary.file_size or stat.S_ISLNK(binary.external_attr >> 16):
                raise ProbeError("Main application executable is missing")
            metadata_bytes = read("iTunesMetadata.plist", 4 * 1024 * 1024)
            metadata = plist_dict(metadata_bytes)
            for key, expected in (("softwareVersionBundleId", bundle), ("bundleShortVersionString", version)):
                if key in metadata and metadata[key] != expected:
                    raise ProbeError("Store metadata does not match the application: " + key)
            main_path = root + "SC_Info/" + executable + ".sinf"
            main_sinf = read(main_path, 16 * 1024 * 1024)
            if not main_sinf:
                raise ProbeError("Empty main application SINF")
            sinfs = [main_path]
            manifest_path = root + "SC_Info/Manifest.plist"
            if manifest_path in entries:
                paths = plist_dict(read(manifest_path)).get("SinfPaths")
                if not isinstance(paths, list) or not paths or len(paths) > 128:
                    raise ProbeError("Invalid multi-component SINF manifest")
                sinfs = []
                for relative in paths:
                    if not isinstance(relative, str) or not safe_path(relative) or not relative.endswith(".sinf"):
                        raise ProbeError("Invalid SINF path")
                    target = root + relative
                    if target in sinfs or not read(target, 16 * 1024 * 1024):
                        raise ProbeError("Duplicate or empty SINF component")
                    sinfs.append(target)
            result = AuditedIPA(path, before, bundle, executable, version, build,
                                metadata_bytes, main_sinf, tuple(sinfs), root + "embedded.mobileprovision" in entries)
    except (zipfile.BadZipFile, RuntimeError, OSError) as error:
        raise ProbeError("IPA could not be read or failed ZIP integrity checks") from error
    if sha256_file(path) != before:
        raise ProbeError("IPA changed during inspection")
    return result


def build_number(value: str) -> tuple[int, ...]:
    if len(value) > 128 or not re.fullmatch(r"\d+(?:\.\d+)*", value):
        raise ProbeError("Cannot safely compare this build version; no upgrade attempted")
    parts = tuple(int(part) for part in value.split("."))
    while len(parts) > 1 and parts[-1] == 0:
        parts = parts[:-1]
    return parts


def validate_identity(ipa: AuditedIPA, command: str, expected_bundle: str) -> None:
    if expected_bundle != ipa.bundle_id:
        raise ProbeError("The expected bundle identifier does not match the IPA")
    if ipa.bundle_id.lower().startswith("com.alipay"):
        raise ProbeError("Alipay is excluded from this experiment")
    if command not in ("Install", "Upgrade"):
        raise ProbeError("Only Install and Upgrade are supported; no uninstall fallback")


def validate_operation(ipa: AuditedIPA, command: str, expected_bundle: str,
                       installed: dict[str, Any] | None) -> None:
    validate_identity(ipa, command, expected_bundle)
    if command == "Install":
        if installed is not None:
            raise ProbeError("App already exists; Install will not overwrite it. Use an explicit Upgrade experiment")
    else:
        if installed is None or installed.get("CFBundleIdentifier") != ipa.bundle_id:
            raise ProbeError("Upgrade requires an existing app with the same bundle identifier")
        if installed.get("IsPlaceholder") or installed.get("IsDemotedApp"):
            raise ProbeError("Restore the placeholder/offloaded app before an Upgrade experiment")
        current = text(installed.get("CFBundleVersion"))
        if build_number(ipa.build_version) < build_number(current):
            raise ProbeError("Downgrades are excluded from this experiment")


def installed_summary(app: dict[str, Any] | None) -> dict[str, Any] | None:
    if app is None:
        return None
    result = {key: app[key] for key in (
        "CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion", "ApplicationType",
        "IsUpgradeable", "IsPlaceholder", "IsDemotedApp", "AppStoreVendable", "BetaApp"
    ) if isinstance(app.get(key), (str, int, bool))}
    raw = app.get("iTunesMetadata")
    if isinstance(raw, bytes):
        try:
            raw = plist_dict(raw)
        except ProbeError:
            raw = None
    if isinstance(raw, dict):
        result["metadata"] = metadata_summary(raw)
    result["store_recognition"] = "requires checking the actual App Store; attributes alone are inconclusive"
    return result
