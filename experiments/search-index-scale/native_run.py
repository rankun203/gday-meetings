"""Run fresh native release-test processes for preparation, search, and mutation."""
import argparse
import json
import os
import subprocess
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument("--checkout", required=True, type=Path)
p.add_argument("--fixture", required=True, type=Path)
p.add_argument("--start", type=int, default=1)
p.add_argument("--end", type=int, default=10)
p.add_argument("--limits", type=int, nargs="+", default=[5, 100])
p.add_argument("--skip-mutations", action="store_true")
p.add_argument("--separate-tasks", action="store_true")
p.add_argument("--idle-ms", type=int, default=0)
p.add_argument("--rotate-limits", action="store_true")
a = p.parse_args()
fixture = a.fixture.resolve()
checkout = a.checkout.resolve()
for scale in range(a.start, a.end + 1):
    offset = (scale - a.start) % len(a.limits) if a.rotate_limits else 0
    limits = a.limits[offset:] + a.limits[:offset]
    cases = [("prepare", 5)] + [("search", limit) for limit in limits]
    if not a.skip_mutations:
        cases.append(("mutation", 5))
    for mode, limit in cases:
        env = os.environ | {"GDAY_NATIVE_FIXTURE": str(fixture), "GDAY_NATIVE_MODE": mode,
                            "GDAY_NATIVE_SCALE": str(scale), "GDAY_NATIVE_LIMIT": str(limit),
                            "GDAY_NATIVE_SEPARATE_TASKS": "1" if a.separate_tasks else "0",
                            "GDAY_NATIVE_IDLE_MS": str(a.idle_ms)}
        log = fixture / f"test-{scale}-{mode}-{limit}.log"
        command = "source apps/client-macos-swift/scripts/common.sh\nswift_package test -c release --skip-build --filter NativeSearchScaleTests -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
        with log.open("w") as f:
            subprocess.run(["/bin/bash", "-c", command], cwd=checkout, env=env, stdout=f, stderr=subprocess.STDOUT, check=True)
        print(json.dumps({"scale": scale, "mode": mode, "limit": limit, "complete": True}), flush=True)
