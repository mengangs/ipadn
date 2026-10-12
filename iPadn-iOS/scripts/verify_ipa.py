#!/usr/bin/env python3
"""Verify the unsigned universal device IPA, including both icon idioms."""
import hashlib
import json
import plistlib
import sys
import zipfile
from pathlib import Path

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
        alternate = icons['CFBundleAlternateIcons']['AppIconFlat']
        assert alternate['CFBundleIconFiles'], 'Missing standalone alternate icon declaration: ' + key
    for filename in ['AppIconFlat60x60@2x.png', 'AppIconFlat60x60@3x.png',
                     'AppIconFlat76x76@2x~ipad.png', 'AppIconFlat83x83@2x~ipad.png']:
        assert prefix + filename in archive.namelist(), 'Missing alternate icon PNG: ' + filename
    manifest = json.loads((ROOT / 'vendor/SAPRuntime/manifest.json').read_text())['files']
    for filename, expected in manifest.items():
        actual = hashlib.sha256(archive.read(prefix + 'SAPRuntime/' + filename)).hexdigest()
        assert actual == expected, 'Bundled runtime hash mismatch: ' + filename
    assert prefix + 'embedded.mobileprovision' not in archive.namelist(), 'Unexpected provisioning profile'
    assert not any(name.startswith(prefix + '_CodeSignature/') for name in archive.namelist()), 'Unexpected signing envelope'

report = {
    'passed': True,
    'version': info['CFBundleShortVersionString'],
    'build': info['CFBundleVersion'],
    'bundle_id': info['CFBundleIdentifier'],
    'checks': ['ZIP CRC integrity', 'iPadn identity', 'phone/pad primary and alternate icon metadata',
               'vendored runtime SHA-256', 'no provisioning profile or signing envelope'],
    'not_run': ['Apple authorization', 'real-device installation', 'launch animation'],
}
(ROOT / 'build').mkdir(exist_ok=True)
(ROOT / 'build/ipa-verification.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(report, ensure_ascii=False, indent=2))
