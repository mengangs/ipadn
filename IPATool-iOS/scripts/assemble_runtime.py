#!/usr/bin/env python3
"""Restore byte-identical signing resources from a pinned public source archive."""
import hashlib
import json
import os
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / 'vendor/SAPRuntime/manifest.json'
OUTPUT = ROOT / 'IPATool/Resources/SAPRuntime'
CACHE = ROOT / '.runtime-cache'

def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''): result.update(block)
    return result.hexdigest()

def main():
    manifest = json.loads(MANIFEST.read_text())
    expected = manifest['files']
    if all((OUTPUT / name).exists() and digest(OUTPUT / name) == sha for name, sha in expected.items()):
        print('All original SAP resources already present and verified')
        return
    if not manifest['source_url'].startswith('https://raw.githubusercontent.com/ScriptingApp/Community-Scripts/'):
        raise ValueError('Untrusted source URL')
    CACHE.mkdir(exist_ok=True); OUTPUT.mkdir(parents=True, exist_ok=True)
    archive = CACHE / 'source.scripting'
    if not archive.exists() or digest(archive) != manifest['archive_sha256']:
        temporary = CACHE / 'source.scripting.tmp'
        try:
            with urllib.request.urlopen(manifest['source_url'], timeout=120) as response, temporary.open('wb') as target:
                size = 0
                for block in iter(lambda: response.read(1024 * 1024), b''):
                    size += len(block)
                    if size > manifest['archive_size']: raise ValueError('Source archive exceeds expected size')
                    target.write(block)
            if size != manifest['archive_size'] or digest(temporary) != manifest['archive_sha256']:
                raise ValueError('Pinned source archive SHA-256 or size mismatch')
            os.replace(temporary, archive)
        finally: temporary.unlink(missing_ok=True)
    with zipfile.ZipFile(archive) as source:
        for name, sha in expected.items():
            if Path(name).name != name: raise ValueError('Unsafe runtime filename')
            data = source.read(manifest['entry_prefix'] + name)
            if hashlib.sha256(data).hexdigest() != sha: raise ValueError('Runtime SHA-256 mismatch: ' + name)
            temporary = OUTPUT / (name + '.tmp')
            temporary.write_bytes(data); os.replace(temporary, OUTPUT / name)
    print('Restored and verified', len(expected), 'original signing resources')

if __name__ == '__main__': main()
