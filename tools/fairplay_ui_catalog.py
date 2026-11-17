"""Catalog coverage for FairPlay UI. Chinese literals are stable source keys."""
import json
import sys
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / 'iPadn-iOS/iPadn/Resources/Localizable.xcstrings'
FILES = ['PackagesView', 'PackageSourceDetailView', 'PackageLibraryRows', 'DecryptDetailView',
         'DecryptHistoryView', 'DecryptHelpView', 'DecryptLogView', 'FairPlayPresentation', 'PackageFileActions']

def keys():
    found = set()
    for name in FILES:
        source = (ROOT / f'iPadn-iOS/iPadn/Views/{name}.swift').read_text(encoding='utf-8')
        for raw in re.findall(r'"((?:\\.|[^"\\])*)"', source):
            if not re.search(r'[\u4e00-\u9fff]', raw) or '\\(' in raw:
                continue
            found.add(raw.replace('\\n', '\n'))
    return found

if __name__ == '__main__':
    catalog = json.loads(CATALOG.read_text(encoding='utf-8'))
    if '--write' in sys.argv:
        import ctypes
        english = dict(line.split('|', 1) for line in (ROOT / 'tools/fairplay_ui_en.txt').read_text(encoding='utf-8').splitlines() if '|' in line)
        labels = {}
        languages = ['ja', 'ko', 'ru', 'es', 'fr', 'de', 'pt-BR', 'ar']
        for line in (ROOT / 'tools/fairplay_ui_labels.txt').read_text(encoding='utf-8').splitlines():
            if not line.strip(): continue
            key, *values = line.split('|')
            assert len(values) == len(languages), key
            labels[key] = dict(zip(languages, values))
        for key, translation in english.items():
            entry = catalog['strings'].setdefault(key, {})
            localizations = entry.setdefault('localizations', {})
            for lang, value in [('zh-Hans', key), ('en', translation)]:
                localizations[lang] = {'stringUnit': {'state': 'translated', 'value': value}}
            buffer = ctypes.create_unicode_buffer(len(key) * 2 + 10)
            if ctypes.windll.kernel32.LCMapStringEx('zh-TW', 0x04000000, key, len(key), buffer, len(buffer), None, None, 0):
                localizations['zh-Hant'] = {'stringUnit': {'state': 'translated', 'value': buffer.value}}
            if translation in labels:
                for lang, value in labels[translation].items():
                    localizations[lang] = {'stringUnit': {'state': 'translated', 'value': value}}
        for line in (ROOT / 'tools/fairplay_ui_notes.txt').read_text(encoding='utf-8').splitlines():
            if not line.strip(): continue
            prefix, *values = line.split('|')
            candidates = [prefix] if prefix in english else [k for k in english if k.startswith(prefix)]
            assert len(candidates) == 1 and len(values) == len(languages), prefix
            localizations = catalog['strings'][candidates[0]]['localizations']
            for lang,value in zip(languages,values):
                localizations[lang] = {'stringUnit': {'state': 'translated', 'value': value}}
        CATALOG.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    missing = sorted(key for key in keys() if not catalog['strings'].get(key, {}).get('localizations', {}).get('en'))
    for key in missing:
        print(key)
    print('MISSING:', len(missing))
