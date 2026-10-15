"""Measure a separate process; output goes to private files, not terminal logs."""
import argparse
import json
import os
import platform
import subprocess
import time
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--output', type=Path, required=True)
p.add_argument('command', nargs=argparse.REMAINDER)
a = p.parse_args()
command = a.command[1:] if a.command[:1] == ['--'] else a.command
if not command:
    p.error('Provide a command after --')
a.output.parent.mkdir(parents=True, exist_ok=True)
start = time.monotonic()
with a.output.with_suffix('.log').open('w') as log:
    process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
    _, status, usage = os.wait4(process.pid, 0)
    process.returncode = os.waitstatus_to_exitcode(status)
wall = time.monotonic() - start
# Darwin reports bytes; Linux reports KiB. GPU/ANE memory is not measured here.
peak = usage.ru_maxrss if platform.system() == 'Darwin' else usage.ru_maxrss * 1024
result = {'wall_seconds': wall, 'user_cpu_seconds': usage.ru_utime,
          'system_cpu_seconds': usage.ru_stime, 'peak_rss_bytes': peak,
          'exit_code': process.returncode, 'platform': platform.platform(),
          'machine': platform.machine(), 'logical_cpus': os.cpu_count()}
a.output.write_text(json.dumps(result, indent=2))
print(json.dumps(result))
raise SystemExit(process.returncode)
