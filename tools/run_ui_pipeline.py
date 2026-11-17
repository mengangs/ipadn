"""Run a local verification step with a UTF-8 log and reliable exit status."""
import subprocess
import sys
import os
from pathlib import Path

root = Path(__file__).resolve().parents[1]
name, *command = sys.argv[1:]
log = root / 'artifacts' / 'uiux' / (name + '.log')
log.parent.mkdir(parents=True, exist_ok=True)
with log.open('w', encoding='utf-8') as stream:
    environment = dict(os.environ, PYTHONUTF8='1', PYTHONIOENCODING='utf-8')
    result = subprocess.run([sys.executable, '-X', 'utf8', *command], cwd=root, stdout=stream, stderr=subprocess.STDOUT, env=environment)
print(f'{name}: exit={result.returncode}; log={log.relative_to(root)}', flush=True)
if result.returncode:
    lines = log.read_text(encoding='utf-8').splitlines()
    for i, line in enumerate(lines):
        if 'error:' in line.lower() and len(line) < 500:
            print('\n'.join(lines[max(0, i-1):i+4]))
sys.exit(result.returncode)
