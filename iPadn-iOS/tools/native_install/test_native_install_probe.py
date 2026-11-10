import asyncio
import contextlib
import io
import json
import plistlib
import tempfile
import unittest
import warnings
import zipfile
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

from ipa_audit import (ProbeError, inspect_ipa, installed_summary, redacted,
                       sha256_file, validate_operation)
from native_install_probe import (NativeInstallError, backend, execute, lookup,
                                  main, parse_args, record_status)


def make_ipa(folder, *, bundle="example.probe.app", build="20", multi=False,
             missing_component=False, metadata_bundle=None, duplicate=False, unsafe=False):
    path = Path(folder) / "测试安装包.ipa"
    info = {"CFBundleIdentifier": bundle, "CFBundleExecutable": "MainBinary",
            "CFBundleShortVersionString": "1.2", "CFBundleVersion": build}
    metadata = {"itemId": 123, "softwareVersionBundleId": metadata_bundle or bundle,
                "bundleShortVersionString": "1.2",
                "com.apple.iTunesStore.downloadInfo": {"accountInfo": {
                    "AppleID": "private@example.com", "DSPersonID": "9876543210", "token": "do-not-export"}}}
    raw_metadata = plistlib.dumps(metadata, fmt=plistlib.FMT_BINARY)
    root = "Payload/Example.app/"
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr(root + "Info.plist", plistlib.dumps(info))
        archive.writestr(root + "MainBinary", b"synthetic-not-an-installable-executable")
        archive.writestr("iTunesMetadata.plist", raw_metadata)
        archive.writestr(root + "SC_Info/MainBinary.sinf", b"main-license\x00\xff")
        archive.writestr(root + "SC_Info/MainBinary.supp", b"preserved-supplement")
        archive.writestr(root + "_CodeSignature/CodeResources", b"preserved-original-code-resources")
        if multi:
            component = "PlugIns/Widget.appex/SC_Info/Widget.sinf"
            # Main SINF deliberately is not the first manifest entry.
            manifest = {"SinfPaths": [component, "SC_Info/MainBinary.sinf"]}
            archive.writestr(root + "SC_Info/Manifest.plist", plistlib.dumps(manifest))
            if not missing_component:
                archive.writestr(root + component, b"widget-license")
        if duplicate:
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                archive.writestr("iTunesMetadata.plist", raw_metadata)
        if unsafe:
            archive.writestr("../unexpected", b"unsafe")
    return path, raw_metadata


class PackageAuditTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)

    def test_store_options_preserve_binary_metadata_and_main_license(self):
        path, raw = make_ipa(self.folder.name, multi=True)
        digest = sha256_file(path)
        ipa = inspect_ipa(path)
        self.assertEqual(ipa.display_version, "1.2")
        self.assertEqual(ipa.build_version, "20")
        self.assertEqual(ipa.options(), {"CFBundleIdentifier": "example.probe.app",
                         "iTunesMetadata": raw, "ApplicationSINF": b"main-license\x00\xff"})
        self.assertNotIn("PackageType", ipa.options())
        self.assertEqual(len(ipa.sinf_paths), 2)
        self.assertEqual(sha256_file(path), digest)

    def test_embedded_comparison_keeps_the_same_ipa(self):
        path, _ = make_ipa(self.folder.name)
        ipa = inspect_ipa(path)
        self.assertEqual(ipa.options("embedded"), {"CFBundleIdentifier": ipa.bundle_id})
        self.assertEqual(sha256_file(path), ipa.sha256)
        with self.assertRaises(ProbeError):
            ipa.options("developer")

    def test_multi_component_missing_license_is_rejected(self):
        path, _ = make_ipa(self.folder.name, multi=True, missing_component=True)
        with self.assertRaises(ProbeError):
            inspect_ipa(path)

    def test_metadata_identity_mismatch_is_rejected(self):
        path, _ = make_ipa(self.folder.name, metadata_bundle="different.app")
        with self.assertRaises(ProbeError):
            inspect_ipa(path)

    def test_duplicate_and_traversal_archives_are_rejected(self):
        for option in ("duplicate", "unsafe"):
            with self.subTest(option=option), self.assertRaises(ProbeError):
                path, _ = make_ipa(self.folder.name, **{option: True})
                inspect_ipa(path)

    def test_reports_exclude_account_and_license_bytes(self):
        path, _ = make_ipa(self.folder.name)
        ipa = inspect_ipa(path)
        output = json.dumps(ipa.summary())
        for secret in ("private@example.com", "9876543210", "do-not-export", "main-license"):
            self.assertNotIn(secret, output)
        self.assertTrue(ipa.summary()["metadata"]["has_account_association"])
        self.assertNotIn("private@example.com", repr(ipa))

    def test_diagnostics_preserve_error_code_without_account_credentials(self):
        source = "MIInstallerErrorDomain Code=64 private@example.com DSID=9876543210 "
        output = redacted(source + "-----BEGIN PRIVATE KEY-----\nsecret\n-----END PRIVATE KEY-----")
        self.assertIn("Code=64", output)
        for secret in ("private@example.com", "9876543210", "secret"):
            self.assertNotIn(secret, output)

    def test_install_never_overwrites_existing_app_and_no_alipay(self):
        path, _ = make_ipa(self.folder.name)
        ipa = inspect_ipa(path)
        validate_operation(ipa, "Install", ipa.bundle_id, None)
        for command, bundle, installed in (
            ("Install", ipa.bundle_id, {"CFBundleIdentifier": ipa.bundle_id}),
            ("Upgrade", ipa.bundle_id, None),
            ("Install", "wrong.bundle", None),
            ("Uninstall", ipa.bundle_id, None),
        ):
            with self.subTest(command=command, bundle=bundle), self.assertRaises(ProbeError):
                validate_operation(ipa, command, bundle, installed)
        alipay = replace(ipa, bundle_id="com.alipay.iphoneclient")
        with self.assertRaises(ProbeError):
            validate_operation(alipay, "Install", alipay.bundle_id, None)

    def test_upgrade_uses_build_not_display_version_and_refuses_downgrade(self):
        path, _ = make_ipa(self.folder.name)
        ipa = inspect_ipa(path)
        installed = {"CFBundleIdentifier": ipa.bundle_id, "CFBundleVersion": "19.0", "CFBundleShortVersionString": "999"}
        validate_operation(ipa, "Upgrade", ipa.bundle_id, installed)
        for build in ("21", "", "unknown"):
            with self.subTest(build=build), self.assertRaises(ProbeError):
                validate_operation(ipa, "Upgrade", ipa.bundle_id, dict(installed, CFBundleVersion=build))
        with self.assertRaises(ProbeError):
            validate_operation(ipa, "Upgrade", ipa.bundle_id, dict(installed, IsPlaceholder=True))

    def test_installed_metadata_is_summarized_and_does_not_claim_store_recognition(self):
        path, raw = make_ipa(self.folder.name)
        output = installed_summary({"CFBundleIdentifier": "example.probe.app", "iTunesMetadata": raw,
                                    "ApplicationDSID": "secret-id", "PairRecord": b"secret-pair"})
        encoded = json.dumps(output)
        self.assertNotIn("secret", encoded)
        self.assertNotIn("private@example.com", encoded)
        self.assertIn("requires checking", output["store_recognition"])

    def test_offline_cli_does_not_load_backend_or_overwrite_ipa(self):
        path, _ = make_ipa(self.folder.name)
        digest = sha256_file(path)
        out = io.StringIO()
        with patch("native_install_probe.backend", side_effect=AssertionError("device access")), contextlib.redirect_stdout(out):
            self.assertEqual(main(["inspect", str(path)]), 0)
            report = json.loads(out.getvalue())
            self.assertTrue(report["success"])
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(main(["inspect", str(path), "--report", str(path)]), 1)
        self.assertEqual(sha256_file(path), digest)


class FakeProxy:
    def __init__(self, ipa, installed=None, error=None):
        self.ipa = ipa
        self.installed = installed
        self.error = error
        self.calls = []

    async def lookup(self, options):
        assert options["BundleIDs"] == [self.ipa.bundle_id]
        return {} if self.installed is None else {self.ipa.bundle_id: self.installed}

    async def install_from_local(self, path, **kwargs):
        self.calls.append(kwargs)
        assert Path(path).read_bytes() == self.ipa.path.read_bytes()
        if self.error:
            raise self.error
        self.installed = {"CFBundleIdentifier": self.ipa.bundle_id,
                          "CFBundleVersion": self.ipa.build_version}

    async def uninstall(self, *args, **kwargs):
        raise AssertionError("Uninstall must never be called")


class ProtocolTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        path, _ = make_ipa(self.folder.name, multi=True)
        self.ipa = inspect_ipa(path)

    async def test_install_and_upgrade_send_exact_options_without_re_signing(self):
        for command in ("Install", "Upgrade"):
            installed = None if command == "Install" else {"CFBundleIdentifier": self.ipa.bundle_id, "CFBundleVersion": "19"}
            proxy = FakeProxy(self.ipa, installed=installed)
            report = {}
            await execute(proxy, self.ipa, command, self.ipa.bundle_id, "store", report)
            self.assertEqual(len(proxy.calls), 1)
            self.assertEqual(proxy.calls[0], {"cmd": command, "options": self.ipa.options(), "developer": False})
            self.assertTrue(report["installed_build_verified"])
            self.assertTrue(report["source_ipa_unchanged"])
            self.assertEqual(report["manual_acceptance"]["actual_app_store_update"], "not_checked")

    async def test_system_failure_is_not_retried_or_converted_to_uninstall(self):
        failure = NativeInstallError({"Error": "ApplicationVerificationFailed", "ErrorDomain": "MIInstallerErrorDomain",
                                     "ErrorCode": 64, "ErrorDescription": "private@example.com could not be upgraded"})
        proxy = FakeProxy(self.ipa, error=failure)
        report = {}
        with self.assertRaises(NativeInstallError) as caught:
            await execute(proxy, self.ipa, "Install", self.ipa.bundle_id, "store", report)
        self.assertEqual(caught.exception.details["ErrorCode"], "64")
        self.assertEqual(len(proxy.calls), 1)
        self.assertNotIn("system_completed", report)
        self.assertTrue(report["staged_ipa_unchanged"])
        self.assertNotIn("private@example.com", json.dumps(caught.exception.details))

    async def test_existing_app_refusal_happens_before_upload(self):
        proxy = FakeProxy(self.ipa, installed={"CFBundleIdentifier": self.ipa.bundle_id})
        with self.assertRaises(ProbeError):
            await execute(proxy, self.ipa, "Install", self.ipa.bundle_id, "store", {})
        self.assertEqual(proxy.calls, [])

    async def test_changed_package_cannot_be_uploaded(self):
        proxy = FakeProxy(self.ipa)
        self.ipa.path.write_bytes(b"changed after inspection")
        with self.assertRaises(ProbeError):
            await execute(proxy, self.ipa, "Install", self.ipa.bundle_id, "store", {})
        self.assertEqual(proxy.calls, [])

    async def test_unknown_inventory_is_not_treated_as_absent(self):
        class Unavailable:
            async def lookup(self, options):
                return None
        with self.assertRaises(ProbeError):
            await lookup(Unavailable(), self.ipa.bundle_id)

    async def test_server_status_requires_completion_and_redacts_errors(self):
        report = {}
        self.assertFalse(record_status({"Status": "Installing", "PercentComplete": 50}, report))
        self.assertTrue(record_status({"Status": "Complete"}, report))
        with self.assertRaises(ProbeError):
            record_status(None, report)
        with self.assertRaises(NativeInstallError):
            record_status({"Error": "InstallFailed", "Status": "Complete"}, report)


class BackendTests(unittest.TestCase):
    def test_installed_backend_api_without_device_access(self):
        try:
            import pymobiledevice3  # noqa: F401
        except ImportError:
            self.skipTest("optional backend not installed; offline checks still run")
        with patch("pymobiledevice3.lockdown.create_using_usbmux", side_effect=AssertionError("device access")):
            create, service = backend()
            self.assertTrue(callable(create))
            self.assertTrue(callable(service.install_from_local))

    def test_actual_backend_serializes_binary_client_options_on_the_wire(self):
        try:
            from pymobiledevice3.services.installation_proxy import InstallationProxyService
        except ImportError:
            self.skipTest("optional backend not installed")

        class Wire:
            sent = None
            async def send_plist(self, value):
                # Round-trip through a real binary plist, as the transport does.
                self.sent = plistlib.loads(plistlib.dumps(value, fmt=plistlib.FMT_BINARY))
            async def recv_plist(self):
                return {"Status": "Complete"}

        class Client(InstallationProxyService):
            async def _watch_completion(self, *args, **kwargs):
                self.completed = record_status(await self.service.recv_plist(), {})

        wire = Wire()
        client = Client(None, service=wire)
        options = {"CFBundleIdentifier": "example.probe.app", "iTunesMetadata": b"bplist00\x00\xff",
                   "ApplicationSINF": b"sinf\x00\xff"}
        asyncio.run(client.send_package("Upgrade", options, None, "PublicStaging/original.ipa"))
        self.assertEqual(wire.sent, {"Command": "Upgrade", "ClientOptions": options,
                                    "PackagePath": "PublicStaging/original.ipa"})
        self.assertTrue(client.completed)

    def test_device_commands_require_explicit_identity_and_no_uninstall_command(self):
        with contextlib.redirect_stderr(io.StringIO()):
            for arguments in (["install", "test.ipa"], ["uninstall", "example.app"]):
                with self.assertRaises(SystemExit):
                    parse_args(arguments)


if __name__ == "__main__":
    unittest.main()
