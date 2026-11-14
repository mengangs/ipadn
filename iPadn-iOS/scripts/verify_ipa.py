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
args = parser.parse_args()
ipa = Path(args.ipa)
prefix = 'Payload/iPadn.app/'
with zipfile.ZipFile(ipa) as archive:
    corrupt = archive.testzip()
    if corrupt is not None:
        raise ValueError('Corrupt IPA entry: ' + corrupt)
    info = plistlib.loads(archive.read(prefix + 'Info.plist'))
    assert info['CFBundleDisplayName'] == 'iPadn', 'Unexpected application name'
    assert info['CFBundleIdentifier'] == 'app.local.iPadn', 'Unexpected bundle identifier'
    assert set(info['UIDeviceFamily']) == {1, 2}, 'Both iPhone and iPad must be supported'
    for key in ['CFBundleIcons', 'CFBundleIcons~ipad']:
        icons = info[key]
        assert icons['CFBundlePrimaryIcon']['CFBundleIconName'] == 'AppIcon', key
        for name in ALTERNATE_ICONS:
            alternate = icons['CFBundleAlternateIcons'][name]
            assert alternate['CFBundleIconFiles'], 'Missing standalone alternate icon declaration: ' + key + ' ' + name
    for name in ALTERNATE_ICONS:
        for suffix in ['60x60@2x.png', '60x60@3x.png', '76x76@2x~ipad.png', '83x83@2x~ipad.png']:
            assert prefix + name + suffix in archive.namelist(), 'Missing alternate icon PNG: ' + name + suffix
    manifest = json.loads((ROOT / 'vendor/SAPRuntime/manifest.json').read_text())['files']
    for filename, expected in manifest.items():
        actual = hashlib.sha256(archive.read(prefix + 'SAPRuntime/' + filename)).hexdigest()
        assert actual == expected, 'Bundled runtime hash mismatch: ' + filename
    assert not any('localhost-test-only' in name or name.endswith('.p12') for name in archive.namelist()), 'Unexpected test or TLS private identity in IPA'
    macpkg = (prefix + 'Unicorn-GPL-2.0.txt') in archive.namelist()
    if macpkg or os.environ.get('IPADN_REQUIRE_MACPKG') == '1':
        executable = archive.read(prefix + info['CFBundleExecutable'])
        for symbol in [b'_iPadnMacPKGDecrypt', b'_iPadnMacPKGStatus', b'_uc_emu_start']:
            assert symbol in executable, 'Mac PKG bridge symbol missing: ' + symbol.decode()
        assert macpkg and prefix + 'ipatool-MIT.txt' in archive.namelist(), 'Missing Mac PKG bridge license notices'
    native = (prefix + 'idevice-MIT.txt') in archive.namelist()
    if native or os.environ.get('IPADN_REQUIRE_NATIVE') == '1':
        executable = archive.read(prefix + info['CFBundleExecutable'])
        for symbol in [b'_iPadnNativeInstall', b'_iPadnNativeLookup', b'_iPadnNativeCancel', b'_iPadnNativeFree',
                       b'_iPadnNativePair', b'_iPadnNativePairCancel']:
            assert symbol in executable, 'Native installation symbol missing: ' + symbol.decode()
        assert native, 'Missing native installation license notice'
        extension = prefix + 'PlugIns/iPadnLiveActivity.appex/'
        assert extension + 'Info.plist' in archive.namelist(), 'Missing pairing Live Activity extension'
        extension_info = plistlib.loads(archive.read(extension + 'Info.plist'))
        assert extension_info['CFBundleIdentifier'] == 'app.local.iPadn.LiveActivity', 'Unexpected extension identifier'
        assert info.get('NSSupportsLiveActivities') is True, 'Live Activities not declared'
        for service in ['_remotepairing._tcp', '_remotepairing-pairable-host._tcp']:
            assert service in info.get('NSBonjourServices', []), 'Missing Bonjour service declaration: ' + service
    assert prefix + 'embedded.mobileprovision' not in archive.namelist(), 'Unexpected provisioning profile'
    assert not any(name.startswith(prefix + '_CodeSignature/') for name in archive.namelist()), 'Unexpected signing envelope'

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
    'version': info['CFBundleShortVersionString'],
    'build': info['CFBundleVersion'],
    'bundle_id': info['CFBundleIdentifier'],
    'macho_build_versions': macho_build_versions,
    'high_refresh_rate': bool(info.get('CADisableMinimumFrameDurationOnPhone')),
    'checks': ['ZIP CRC integrity', 'iPadn identity', 'phone/pad primary and alternate icon metadata',
               'vendored runtime SHA-256', 'no provisioning profile or signing envelope',
               'Mach-O LC_BUILD_VERSION sdk >= ' + args.min_sdk if args.min_sdk else 'Mach-O LC_BUILD_VERSION present',
               'CADisableMinimumFrameDurationOnPhone=true' if args.require_high_refresh else 'high refresh opt-in checked',
               'Mac PKG bridge linked' if macpkg else 'Mac PKG bridge not linked',
               'native installation linked' if native else 'native installation not linked'],
    'not_run': ['Apple authorization', 'real-device installation', 'launch animation'],
}
(ROOT / 'build').mkdir(exist_ok=True)
(ROOT / 'build/ipa-verification.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(report, ensure_ascii=False, indent=2))
