#!/usr/bin/env python3
"""Writes the lite IPA: the standard one without the app extension.

The extension holds the Live Activities (pairing, download progress) and
the Home Screen widget. Without it the app needs a single App ID, which
helps signing tools and free accounts with an App ID limit.

Usage: make_lite_ipa.py <standard.ipa> <lite.ipa>
"""
import sys
import zipfile

EXTENSION = 'Payload/iPadn.app/PlugIns/iPadnLiveActivity.appex/'


def make_lite(source_path: str, target_path: str) -> int:
    removed = 0
    with zipfile.ZipFile(source_path) as source, zipfile.ZipFile(target_path, 'w', zipfile.ZIP_DEFLATED) as target:
        names = source.namelist()
        plugins = EXTENSION.rsplit('/', 2)[0] + '/'
        # PlugIns/ itself goes too when the extension was all it held.
        empty = all(name == plugins or name.startswith(EXTENSION) for name in names if name.startswith(plugins))
        for item in source.infolist():
            if item.filename.startswith(EXTENSION) or (empty and item.filename == plugins):
                removed += 1
                continue
            # The original entry keeps its compression and file permissions.
            target.writestr(item, source.read(item.filename))
    if removed == 0:
        raise SystemExit('No app extension found in ' + source_path)
    return removed


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    count = make_lite(sys.argv[1], sys.argv[2])
    print(f'Removed {count} extension entries -> {sys.argv[2]}')
