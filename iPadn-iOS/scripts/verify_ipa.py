#!/usr/bin/env python3
"""Verify the unsigned universal device IPA, including both icon idioms."""
import hashlib
import json
import os
import plistlib
import sys
import zipfile
from pathlib import Path
ALTERNATE_ICONS = ['AppIconFlat', 'AppIconLight', 'AppIconDark', 'AppIconFlatLight', 'AppIconFlatDark']

ROOT = Path(__file__).resolve().parents[1]
ipa = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'build/iPadn-unsigned.ipa'
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
    assert prefix + 'embedded.mobileprovision' not in archive.namelist(), 'Unexpected provisioning profile'
    assert not any(name.startswith(prefix + '_CodeSignature/') for name in archive.namelist()), 'Unexpected signing envelope'

report = {
    'passed': True,
    'version': info['CFBundleShortVersionString'],
    'build': info['CFBundleVersion'],
    'bundle_id': info['CFBundleIdentifier'],
    'checks': ['ZIP CRC integrity', 'iPadn identity', 'phone/pad primary and alternate icon metadata',
               'vendored runtime SHA-256', 'no provisioning profile or signing envelope',
               'Mac PKG bridge linked' if macpkg else 'Mac PKG bridge not linked'],
    'not_run': ['Apple authorization', 'real-device installation', 'launch animation'],
}
(ROOT / 'build').mkdir(exist_ok=True)
(ROOT / 'build/ipa-verification.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(report, ensure_ascii=False, indent=2))
