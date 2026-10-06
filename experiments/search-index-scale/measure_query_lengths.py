"""Measure fixed-shape Core ML functions and attach generic query vectors."""

import argparse
import json
import subprocess
from pathlib import Path

import numpy as np

p = argparse.ArgumentParser()
p.add_argument("--benchmark", type=Path, required=True)
p.add_argument("--model", type=Path, required=True)
p.add_argument("--probes", type=Path, required=True)
p.add_argument("--output", type=Path, required=True)
a = p.parse_args()
base = np.load(a.output / "queries.npy")
assert len(base) == 32, "Use a fresh fixture to avoid appending twice"
vectors = []
labels = ["perturbed-corpus"] * 32
reports = []
for n in [8, 32, 64, 96, 128, 256, 512]:
    dest = a.probes / f"result-{n}.json"
    function = "query128" if n <= 128 else "passage512"
    subprocess.run(
        [
            str(a.benchmark.resolve()),
            str(a.model),
            str(a.probes / f"length-{n}.json"),
            "all",
            str(dest),
            function,
        ],
        check=True,
    )
    report = json.loads(dest.read_text())
    vectors.extend(report.pop("vectors"))
    labels.extend([str(n)] * 4)
    reports.append(dict(tokens=n, function=function, **report))
x = np.asarray(vectors, dtype="f4")
x /= np.linalg.norm(x, axis=1, keepdims=True)
np.save(a.output / "queries.npy", np.concatenate([base, x]))
(a.output / "query-labels.json").write_text(json.dumps(labels))
(a.output / "query-length-timings.json").write_text(json.dumps(reports, indent=2))
