#!/usr/bin/env python3
"""Independent native Install/Upgrade probe. No signing or uninstall operations.

Offline commands use only the Python standard library. Device commands use the
version pinned in requirements.txt and an already trusted, explicitly named USB
device. This tool is deliberately not wired into iPadn's production installer.
"""
from __future__ import annotations

import argparse
import asyncio
import importlib.metadata
import inspect
import json
import logging
import shutil
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from uuid import uuid4

from ipa_audit import (AuditedIPA, ProbeError, inspect_ipa, installed_summary,
                       redacted, sha256_file, validate_identity, validate_operation)

PINNED_BACKEND = "11.50.3"
ATTRIBUTES = ["CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion",
              "ApplicationType", "IsUpgradeable", "IsPlaceholder", "IsDemotedApp",
              "AppStoreVendable", "BetaApp", "iTunesMetadata"]
REPORT_DIRECTORY = Path(__file__).resolve().parents[3] / ".build/native-install-reports"


class NativeInstallError(ProbeError):
    def __init__(self, response: dict[str, Any]):
        # Preserve the server's error name/domain/code when available, never
        # log its entire response (which can include account material).
        self.details = {key: redacted(response[key]) for key in (
            "Error", "ErrorDescription", "ErrorDomain", "ErrorCode", "Status"
        ) if isinstance(response.get(key), (str, int))}
        super().__init__(self.details.get("Error", "InstallationProxy failed"))


def backend():
    try:
        version = importlib.metadata.version("pymobiledevice3")
    except importlib.metadata.PackageNotFoundError as error:
        raise ProbeError("Install the pinned requirements.txt in an isolated environment first") from error
    if version != PINNED_BACKEND:
        raise ProbeError("Backend version differs from requirements.txt; refusing an untested device API")
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.installation_proxy import InstallationProxyService
    parameters = inspect.signature(InstallationProxyService.install_from_local).parameters
    if not all(key in parameters for key in ("package_path", "cmd", "options", "developer")):
        raise ProbeError("Unsupported InstallationProxy API")
    return create_using_usbmux, InstallationProxyService


async def lookup(proxy: Any, bundle_id: str) -> dict[str, Any] | None:
    response = await proxy.lookup(options={
        "BundleIDs": [bundle_id], "ApplicationType": "Any", "ReturnAttributes": ATTRIBUTES,
    })
    if not isinstance(response, dict):
        # Unknown inventory must never be treated as "not installed".
        raise ProbeError("Device did not return a valid app inventory")
    app = response.get(bundle_id)
    if app is not None and not isinstance(app, dict):
        raise ProbeError("Device returned an invalid application record")
    return app


async def execute(proxy: Any, ipa: AuditedIPA, command: str, expected_bundle: str,
                  mode: str, report: dict[str, Any]) -> None:
    validate_identity(ipa, command, expected_bundle)
    before = await lookup(proxy, ipa.bundle_id)
    report["before"] = installed_summary(before)
    validate_operation(ipa, command, expected_bundle, before)
    options = ipa.options(mode)
    with tempfile.TemporaryDirectory(prefix="ipadn-native-probe-") as temporary:
        staged = Path(temporary) / "original.ipa"
        shutil.copyfile(ipa.path, staged)
        if sha256_file(staged) != ipa.sha256:
            raise ProbeError("IPA changed before upload; no installation attempted")
        report["upload_or_install_started"] = True
        try:
            # Raw .ipa bytes; no directory conversion and no Developer override.
            await proxy.install_from_local(str(staged), cmd=command, options=options, developer=False)
            report["system_completed"] = True
        finally:
            for key, path in (("staged_ipa_unchanged", staged), ("source_ipa_unchanged", ipa.path)):
                try:
                    report[key] = sha256_file(path) == ipa.sha256
                except OSError:
                    report[key] = False
            try:
                report["after"] = installed_summary(await asyncio.wait_for(lookup(proxy, ipa.bundle_id), timeout=8))
            except Exception as error:
                report["after_lookup_error"] = type(error).__name__
    after = report.get("after")
    if not report["source_ipa_unchanged"] or not report["staged_ipa_unchanged"]:
        raise ProbeError("IPA changed during the experiment; inspect the report before any further action")
    if not after or after.get("CFBundleIdentifier") != ipa.bundle_id or after.get("CFBundleVersion") != ipa.build_version:
        raise ProbeError("System completed but the expected installed build could not be confirmed")
    report["installed_build_verified"] = True
    report["manual_acceptance"] = {
        "app_store_open_or_update": "not_checked",
        "actual_app_store_update": "not_checked",
        "desktop_classification": "not_checked",
        "existing_app_data_preserved": "not_checked",
        "reboot_persistence": "not_checked",
    }


def record_status(response: Any, report: dict[str, Any]) -> bool:
    if not isinstance(response, dict) or not response:
        raise ProbeError("InstallationProxy disconnected before a final status; completion is unknown")
    event = {key: redacted(response[key]) if isinstance(response[key], str) else response[key]
             for key in ("Status", "PercentComplete") if isinstance(response.get(key), (str, int))}
    report.setdefault("events", []).append(event)
    report["events"] = report["events"][-100:]
    if response.get("Error"):
        raise NativeInstallError(response)
    return response.get("Status") == "Complete"


async def device_command(args: argparse.Namespace, report: dict[str, Any], ipa: AuditedIPA | None) -> None:
    create, base = backend()

    class ObservedProxy(base):
        async def _watch_completion(self, handler=None, *unused, desc="install"):
            while True:
                response = await self.service.recv_plist()
                if record_status(response, report):
                    return

    # autopair=False permits existing trusted pairing only: no new trust prompt,
    # device registration, developer mode change or Wi-Fi pairing modification.
    async with await create(serial=args.udid, connection_type="USB", autopair=False) as lockdown:
        report["device"] = {key: lockdown.all_values[key] for key in ("ProductVersion", "ProductType")
                            if isinstance(lockdown.all_values.get(key), str)}
        async with ObservedProxy(lockdown) as proxy:
            if args.command == "lookup":
                report["installed"] = installed_summary(await lookup(proxy, args.bundle_id))
            else:
                assert ipa is not None
                await execute(proxy, ipa, args.command.title(), args.expected_bundle_id, args.options_mode, report)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    offline = commands.add_parser("inspect", help="Read-only IPA/material inspection; no device access")
    offline.add_argument("ipa", type=Path)
    offline.add_argument("--options-mode", choices=("store", "embedded"), default="store")
    offline.add_argument("--report", type=Path)
    commands.add_parser("check-backend", help="Validate the pinned Python API without contacting a device")
    for name in ("lookup", "install", "upgrade"):
        sub = commands.add_parser(name)
        sub.add_argument("--udid", required=True, help="Explicit, already trusted USB device")
        sub.add_argument("--timeout", type=int, default=300)
        sub.add_argument("--report", type=Path)
        if name == "lookup":
            sub.add_argument("--bundle-id", required=True)
        else:
            sub.add_argument("ipa", type=Path)
            sub.add_argument("--expected-bundle-id", required=True, help="Must match the exact IPA")
            sub.add_argument("--options-mode", choices=("store", "embedded"), default="store")
    result = parser.parse_args(argv)
    if hasattr(result, "timeout") and not 10 <= result.timeout <= 900:
        parser.error("timeout must be between 10 and 900 seconds")
    return result


def main(argv: list[str] | None = None) -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    args = parse_args(argv)
    # Third-party DEBUG logging can contain request plists and account metadata.
    logging.disable(logging.CRITICAL)
    report: dict[str, Any] = {"schema": 1, "command": args.command,
                              "started_at": datetime.now(timezone.utc).isoformat(), "success": False}
    code = 1
    try:
        destination = getattr(args, "report", None)
        if destination is not None and destination.exists():
            raise ProbeError("Report path already exists; existing files will not be overwritten")
        ipa = inspect_ipa(args.ipa) if hasattr(args, "ipa") else None
        if ipa:
            report["package"] = ipa.summary(args.options_mode)
        if args.command == "check-backend":
            backend()
            report["backend_version"] = PINNED_BACKEND
        elif args.command != "inspect":
            if ipa is not None:
                validate_identity(ipa, args.command.title(), args.expected_bundle_id)
            asyncio.run(asyncio.wait_for(device_command(args, report, ipa), timeout=args.timeout))
        report["success"] = True
        code = 0
    except (KeyboardInterrupt, asyncio.CancelledError):
        report["error"] = {"type": "Cancelled", "completion": "unknown if already dispatched; never auto-retry"}
        code = 130
    except Exception as error:
        report["error"] = {"type": type(error).__name__, "message": redacted(error) if isinstance(error, ProbeError)
                           else "Transport/runtime failure; no automatic retry. Capture device logs separately."}
        if isinstance(error, NativeInstallError):
            report["error"]["system"] = error.details
        if isinstance(error, TimeoutError):
            report["error"]["completion"] = "unknown if already dispatched; never auto-retry"
    report["finished_at"] = datetime.now(timezone.utc).isoformat()
    # Reports contain summaries, never raw metadata, SINF, pair records or UDIDs.
    output = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    destination = getattr(args, "report", None)
    if destination is None and args.command in ("lookup", "install", "upgrade"):
        destination = REPORT_DIRECTORY / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid4().hex + ".json")
    if destination is not None:
        destination.parent.mkdir(parents=True, exist_ok=True)
        try:
            with destination.open("x", encoding="utf-8") as target:
                target.write(output)
        except OSError as error:
            report["report_write_error"] = type(error).__name__
            report["success"] = False
            output = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
            code = 1
    print(output, end="")
    return code


if __name__ == "__main__":
    raise SystemExit(main())
