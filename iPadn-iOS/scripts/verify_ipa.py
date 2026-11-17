#!/usr/bin/env python3
"""Verify the unsigned universal device IPA, including both icon idioms."""
import argparse
import hashlib
import json
import os
import plistlib
import struct
import zipfile
from pathlib import Path

ALTERNATE_ICONS = ['AppIconAuto', 'AppIconFlat', 'AppIconLight', 'AppIconDark', 'AppIconFlatLight', 'AppIconFlatDark']
DEFAULT_ALLOWED_BUNDLE_IDS = ('app.local.iPadn', 'app.local.iPadn.fp')
PROHIBITED_SECRET_EXTENSIONS = ('.p12', '.mobileprovision', '.key', '.pem', '.profraw', '.dll', '.exe', '.dylib', '.a')
PROHIBITED_SECRET_BASENAMES = {'signing.json'}
STRICT_OSS_EXTENSIONS = ('.so', '.wasm')
STRICT_OSS_BASENAMES = {'libcoreadi.so', 'libstoreservicescore.so', 'sap.wasm', 'unicorn_x86.js', 'storeagent', 'corefp', 'fairplayd'}
LC_BUILD_VERSION = 0x32
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
PLATFORM_IOS = 2


def parse_version_tuple(text: str) -> tuple[int, int, int]:
    parts = [int(p) for p in text.strip().split('.')]
    while len(parts) < 3:
        parts.append(0)
    return (parts[0], parts[1], parts[2])


def decode_version_tuple(value: int) -> tuple[int, int, int]:
    return (value >> 16, (value >> 8) & 0xFF, value & 0xFF)


def format_version_tuple(version: tuple[int, int, int]) -> str:
    return '.'.join(str(part) for part in version)


def _read_thin_ios_versions(data: bytes, offset: int) -> list[dict[str, str]]:
    if offset + 32 > len(data) or struct.unpack_from('<I', data, offset)[0] != MH_MAGIC_64:
        return []
    ncmds = struct.unpack_from('<I', data, offset + 16)[0]
    cursor = offset + 32
    versions = []
    for _ in range(ncmds):
        if cursor + 8 > len(data):
            break
        cmd, size = struct.unpack_from('<II', data, cursor)
        if cmd == LC_BUILD_VERSION and cursor + 20 <= len(data):
            platform, minos, sdk = struct.unpack_from('<III', data, cursor + 8)
            if platform == PLATFORM_IOS:
                versions.append({
                    'minos': format_version_tuple(decode_version_tuple(minos)),
                    'sdk': format_version_tuple(decode_version_tuple(sdk)),
                })
        cursor += size
    return versions


def inspect_macho_ios_versions(blob: bytes) -> list[dict[str, str]]:
    if len(blob) < 32:
        return []
    magic_be = struct.unpack_from('>I', blob, 0)[0]
    if magic_be in (FAT_MAGIC, FAT_MAGIC_64):
        count = struct.unpack_from('>I', blob, 4)[0]
        versions = []
        for i in range(count):
            offset = struct.unpack_from('>I', blob, 8 + i * 20 + 8)[0] if magic_be == FAT_MAGIC else struct.unpack_from('>Q', blob, 8 + i * 32 + 8)[0]
            versions.extend(_read_thin_ios_versions(blob, offset))
        return versions
    return _read_thin_ios_versions(blob, 0)


ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('ipa', nargs='?', default=str(ROOT / 'build/iPadn-unsigned.ipa'))
parser.add_argument('--min-sdk', default=os.environ.get('IPADN_REQUIRE_MIN_SDK') or None,
                    help='Fail if any iOS executable reports Mach-O LC_BUILD_VERSION sdk lower than this version (e.g. 26.0). Note: checking this tag does not verify full newer-SDK compilation for xtool builds.')
parser.add_argument('--require-high-refresh', action='store_true',
                    default=os.environ.get('IPADN_REQUIRE_HIGH_REFRESH') == '1')
parser.add_argument('--bundle-id', action='append', default=[],
                    help='Additional allowed CFBundleIdentifier for local device signing verification (or set IPADN_ALLOWED_BUNDLE_IDS).')
parser.add_argument('--lite', action='store_true',
                    help='Verify lite variant where PlugIns/iPadnLiveActivity.appex has been removed.')
parser.add_argument('--strict-oss', action='store_true',
                    help='Also reject proprietary binaries or unsourced prebuilt artifacts (e.g., .so, .wasm, unicorn_x86.js).')
args = parser.parse_args()
allowed_bundle_ids = set(DEFAULT_ALLOWED_BUNDLE_IDS)
for value in [*os.environ.get('IPADN_ALLOWED_BUNDLE_IDS', '').split(','), *args.bundle_id]:
    cleaned = value.strip()
    if cleaned:
        allowed_bundle_ids.add(cleaned)
ipa = Path(args.ipa)
prefix = 'Payload/iPadn.app/'
with zipfile.ZipFile(ipa) as archive:
    corrupt = archive.testzip()
    if corrupt is not None:
        raise ValueError('Corrupt IPA entry: ' + corrupt)
    namelist = archive.namelist()
    info = plistlib.loads(archive.read(prefix + 'Info.plist'))
    assert info['CFBundleDisplayName'] == 'iPadn', 'Unexpected application name'
    assert info['CFBundleIdentifier'] in allowed_bundle_ids, f"Unexpected bundle identifier: {info['CFBundleIdentifier']}"
    assert set(info['UIDeviceFamily']) == {1, 2}, 'Both iPhone and iPad must be supported'
    for key in ['CFBundleIcons', 'CFBundleIcons~ipad']:
        icons = info[key]
        assert icons['CFBundlePrimaryIcon']['CFBundleIconName'] == 'AppIcon', key
        for name in ALTERNATE_ICONS:
            alternate = icons['CFBundleAlternateIcons'][name]
            assert alternate['CFBundleIconFiles'], 'Missing standalone alternate icon declaration: ' + key + ' ' + name
    for name in ALTERNATE_ICONS:
        for suffix in ['60x60@2x.png', '60x60@3x.png', '76x76@2x~ipad.png', '83x83@2x~ipad.png']:
            assert prefix + name + suffix in namelist, 'Missing alternate icon PNG: ' + name + suffix
    manifest = json.loads((ROOT / 'vendor/SAPRuntime/manifest.json').read_text(encoding='utf-8'))['files']
    runtime_prefix = prefix + 'SAPRuntime/'
    runtime_entries = {
        entry[len(runtime_prefix):]: entry
        for entry in namelist
        if entry.startswith(runtime_prefix) and not entry.endswith('/')
    }
    assert set(runtime_entries.keys()) == set(manifest.keys()), (
        f'Bundled SAPRuntime files differ from manifest: actual={sorted(runtime_entries)} expected={sorted(manifest)}'
    )
    for filename, expected in manifest.items():
        actual = hashlib.sha256(archive.read(runtime_prefix + filename)).hexdigest()
        assert actual == expected, 'Bundled runtime hash mismatch: ' + filename
    for entry in namelist:
        if entry.endswith('/'):
            continue
        lower = entry.lower()
        base = os.path.basename(lower)
        assert not lower.endswith(PROHIBITED_SECRET_EXTENSIONS), 'Prohibited secret or dynamic binary file in IPA: ' + entry
        assert base not in PROHIBITED_SECRET_BASENAMES, 'Unexpected signing secret in IPA: ' + entry
        assert 'localhost-test-only' not in lower, 'Unexpected test identity in IPA: ' + entry
        if args.strict_oss:
            assert not lower.endswith(STRICT_OSS_EXTENSIONS), 'Prohibited proprietary/unsourced runtime file in IPA (--strict-oss): ' + entry
            assert base not in STRICT_OSS_BASENAMES, 'Prohibited proprietary/unsourced artifact in IPA (--strict-oss): ' + entry
    for required_notice in [
        prefix + 'ZIPFoundation-MIT.txt',
        prefix + 'RevealAnimations/LICENSE.txt',
        prefix + 'RevealAnimations/NOTICE.txt',
        prefix + 'SAPRuntime/Go-BSD-3-Clause.txt',
        prefix + 'SAPRuntime/LGPL-2.0.txt',
    ]:
        assert required_notice in namelist, 'Missing third-party license notice in IPA: ' + required_notice

    executable = archive.read(prefix + info['CFBundleExecutable'])
    assert b'fp_decrypt_file' in executable, 'FairPlayCore C symbol missing (fp_decrypt_file)'

    macpkg_symbols = [b'_iPadnMacPKGDecrypt', b'_iPadnMacPKGStatus', b'_uc_emu_start']
    has_macpkg_symbols = any(symbol in executable for symbol in macpkg_symbols)
    macpkg = has_macpkg_symbols or (prefix + 'Unicorn-GPL-2.0.txt') in namelist
    if macpkg or os.environ.get('IPADN_REQUIRE_MACPKG') == '1':
        for symbol in macpkg_symbols:
            assert symbol in executable, 'Mac PKG bridge symbol missing: ' + symbol.decode()
        assert (prefix + 'Unicorn-GPL-2.0.txt') in namelist and (prefix + 'ipatool-MIT.txt') in namelist, (
            'Missing Mac PKG bridge license notices (Unicorn-GPL-2.0.txt / ipatool-MIT.txt)'
        )
    native_symbols = [b'_iPadnNativeInstall', b'_iPadnNativeLookup', b'_iPadnNativeCancel', b'_iPadnNativeFree',
                      b'_iPadnNativePair', b'_iPadnNativePairCancel']
    has_native_symbols = any(symbol in executable for symbol in native_symbols)
    native = has_native_symbols or (prefix + 'idevice-MIT.txt') in namelist
    extension = prefix + 'PlugIns/iPadnLiveActivity.appex/'
    if args.lite:
        assert not any(name.startswith(extension) for name in namelist), 'Lite IPA must not contain Live Activity extension'
    if native or os.environ.get('IPADN_REQUIRE_NATIVE') == '1':
        for symbol in native_symbols:
            assert symbol in executable, 'Native installation symbol missing: ' + symbol.decode()
        assert (prefix + 'idevice-MIT.txt') in namelist, 'Missing native installation license notice (idevice-MIT.txt)'
        if not args.lite:
            assert extension + 'Info.plist' in namelist, 'Missing pairing Live Activity extension'
            extension_info = plistlib.loads(archive.read(extension + 'Info.plist'))
            assert extension_info['CFBundleIdentifier'].endswith('.LiveActivity'), 'Unexpected extension identifier'
        assert info.get('NSSupportsLiveActivities') is True, 'Live Activities not declared'
        for service in ['_remotepairing._tcp', '_remotepairing-pairable-host._tcp']:
            assert service in info.get('NSBonjourServices', []), 'Missing Bonjour service declaration: ' + service
    assert prefix + 'embedded.mobileprovision' not in namelist, 'Unexpected provisioning profile'
    assert not any(name.startswith(prefix + '_CodeSignature/') for name in namelist), 'Unexpected signing envelope'

    executable_paths = [prefix + info['CFBundleExecutable']]
    for entry in sorted(archive.namelist()):
        if entry.startswith(prefix + 'PlugIns/') and entry.endswith('.appex/Info.plist'):
            ext_info = plistlib.loads(archive.read(entry))
            executable_paths.append(entry[:-len('Info.plist')] + ext_info['CFBundleExecutable'])
    macho_build_versions = {}
    for exec_path in executable_paths:
        versions = inspect_macho_ios_versions(archive.read(exec_path))
        assert versions, 'Missing iOS LC_BUILD_VERSION in executable: ' + exec_path
        macho_build_versions[exec_path] = versions
        if args.min_sdk:
            required = parse_version_tuple(args.min_sdk)
            for item in versions:
                assert parse_version_tuple(item['sdk']) >= required, (
                    f"{exec_path} has Mach-O LC_BUILD_VERSION sdk={item['sdk']} (< {args.min_sdk}); "
                    'run scripts/xtool_postbuild.py before deploying'
                )
    if args.require_high_refresh:
        assert info.get('CADisableMinimumFrameDurationOnPhone') is True, 'Missing CADisableMinimumFrameDurationOnPhone=true'

report = {
    'passed': True,
    'lite': args.lite,
    'strict_oss': args.strict_oss,
    'version': info['CFBundleShortVersionString'],
    'build': info['CFBundleVersion'],
    'bundle_id': info['CFBundleIdentifier'],
    'macho_build_versions': macho_build_versions,
    'high_refresh_rate': bool(info.get('CADisableMinimumFrameDurationOnPhone')),
    'checks': ['ZIP CRC integrity', 'iPadn identity', 'phone/pad primary and alternate icon metadata',
               'vendored runtime SHA-256 (bijective)', 'secret and binary scan clean',
               'third-party license notices (ZIPFoundation, RevealAnimations, SAPRuntime BSD/LGPL)',
               'FairPlayCore C core linked',
               'no provisioning profile or signing envelope',
               'lite mode (LiveActivity stripped)' if args.lite else 'standard mode',
               'Mach-O LC_BUILD_VERSION sdk >= ' + args.min_sdk if args.min_sdk else 'Mach-O LC_BUILD_VERSION present',
               'CADisableMinimumFrameDurationOnPhone=true' if args.require_high_refresh else 'high refresh opt-in checked',
               'Mac PKG bridge linked' if macpkg else 'Mac PKG bridge not linked',
               'native installation linked' if native else 'native installation not linked'],
    'not_run': ['Apple authorization', 'real-device installation', 'launch animation'],
}
(ROOT / 'build').mkdir(exist_ok=True)
report_name = 'build/ipa-lite-verification.json' if args.lite else 'build/ipa-verification.json'
(ROOT / report_name).write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print(json.dumps(report, ensure_ascii=False, indent=2))
