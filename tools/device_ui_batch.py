"""Finite HID QA batch over the documented persistent ios-control session.

Input is a JSON array of screenshot-pixel commands; optional wait_ms is solely
for observing real UI animations during tests, never used by application routing.
"""
import json
import subprocess
import sys
import time
from pathlib import Path

controller = Path(r'D:\iOS-Dev\.agents\skills\ios-real-device-workflow\scripts\ios-control.py')
commands = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
process = subprocess.Popen([sys.executable,'-X','utf8',str(controller),'session'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding='utf-8')
try:
    line=process.stdout.readline()
    if not line or json.loads(line).get('op') != 'ready': raise RuntimeError('HID session did not become ready')
    print('HID ready',flush=True)
    for item in commands:
        delay=item.pop('wait_ms',0)
        if delay: time.sleep(min(delay,3000)/1000)
        process.stdin.write(json.dumps(item)+'\n'); process.stdin.flush()
        response=json.loads(process.stdout.readline())
        if not response.get('ok'): raise RuntimeError(response)
        print(json.dumps(response,ensure_ascii=False),flush=True)
    process.stdin.write('{"op":"quit"}\n');process.stdin.flush()
    process.wait(timeout=15)
finally:
    if process.poll() is None: process.terminate()
