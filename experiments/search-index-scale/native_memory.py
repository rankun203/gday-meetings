"""Probe autorelease lifetime without changing the production search implementation."""
import argparse
import json
import os
import subprocess
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument("--checkout", required=True, type=Path)
p.add_argument("--fixture", required=True, type=Path)
p.add_argument("--output", required=True, type=Path)
a = p.parse_args()
fixture = a.fixture.resolve()
baseline = json.loads((fixture / "search-10-top5.json").read_text())
output = {
    "scale": 10,
    "windows": 390660,
    "limit": 5,
    "scope": "Actual production retrieval; test-only task and autorelease lifetime diagnostics",
    "cacheCondition": "Fresh processes; filesystem caches not cleared",
    "cases": [],
}
command = "source apps/client-macos-swift/scripts/common.sh\nswift_package test -c release --skip-build --filter NativeSearchScaleTests -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
for name, flag in [("separate-tasks", "GDAY_NATIVE_SEPARATE_TASKS"),
                   ("autorelease-pool", "GDAY_NATIVE_AUTORELEASE_POOL")]:
    env = os.environ | {
        "GDAY_NATIVE_FIXTURE": str(fixture), "GDAY_NATIVE_MODE": "search",
        "GDAY_NATIVE_SCALE": "10", "GDAY_NATIVE_LIMIT": "5",
        "GDAY_NATIVE_QUERY_COUNT": "3", "GDAY_NATIVE_IDLE_MS": "200",
        "GDAY_NATIVE_REPORT_SUFFIX": "-" + name, flag: "1",
    }
    with (fixture / f"test-memory-{name}.log").open("w") as log:
        subprocess.run(["/bin/bash", "-c", command], cwd=a.checkout.resolve(),
                       env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    result = json.loads((fixture / f"search-10-top5-{name}.json").read_text())
    for actual, expected in zip(result["queries"], baseline["queries"]):
        assert actual["ids"] == expected["ids"]
        assert actual["scores"] == expected["scores"]
        del actual["ids"]
        del actual["scores"]
    result["resultsIdenticalToBaseline"] = True
    output["cases"].append(result)
    print(name + " complete", flush=True)
a.output.write_text(json.dumps(output, indent=2) + "\n")
