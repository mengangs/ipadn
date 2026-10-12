#!/usr/bin/env python3
"""Verify and copy the runtime committed to this repository. No network access."""
import hashlib
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / 'vendor/SAPRuntime'
OUTPUT = ROOT / 'iPadn/Resources/SAPRuntime'

def main():
    expected = json.loads((VENDOR / 'manifest.json').read_text())['files']
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for name, sha in expected.items():
        if Path(name).name != name: raise ValueError('Unsafe runtime filename')
        data = (VENDOR / 'files' / name).read_bytes()
        if hashlib.sha256(data).hexdigest() != sha: raise ValueError('Vendored runtime SHA-256 mismatch: ' + name)
        target = OUTPUT / name
        if target.exists() and target.read_bytes() == data: continue
        temporary = OUTPUT / (name + '.tmp')
        temporary.write_bytes(data); os.replace(temporary, target)
    print('Verified', len(expected), 'local runtime resources; no upstream download required')

if __name__ == '__main__': main()
