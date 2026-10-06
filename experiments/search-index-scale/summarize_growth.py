"""Describe observed resource growth; do not extrapolate beyond the measured grid."""

import argparse
import json
from pathlib import Path

import numpy as np


def fit(windows, values, unit):
    x = np.asarray(windows, dtype=float) / 100000
    y = np.asarray(values, dtype=float)
    slope, intercept = np.polyfit(x, y, 1)
    residual = y - (intercept + slope * x)
    total = float(np.sum((y - y.mean()) ** 2))
    return {
        "unit": unit,
        "per100000Windows": float(slope),
        "intercept": float(intercept),
        "rSquared": 1 - float(np.sum(residual**2)) / total if total else None,
        "maximumAbsoluteResidual": float(np.max(np.abs(residual))),
        "observations": len(x),
        "minimumWindows": min(windows),
        "maximumWindows": max(windows),
    }


def main():
    p = argparse.ArgumentParser()
    p.add_argument("directory", type=Path)
    a = p.parse_args()
    native = json.loads((a.directory / "native_limit_measurements.json").read_text())
    hnsw = json.loads((a.directory / "hnsw_measurements.json").read_text())
    sqlite = json.loads((a.directory / "diskann_measurements.json").read_text())
    result = {
        "scope": "Descriptive least-squares fits over all ten measured scales; no extrapolation",
        "processMemoryScope": "Includes benchmark runtime; excludes embedding model and OS filesystem cache",
        "engines": {},
    }
    for precision in hnsw["precisions"]:
        rows = precision["stages"]
        assert len(rows) == 10 and all("afterOpen" in r["search"] for r in rows)
        windows = [r["windows"] for r in rows]
        result["engines"]["hnsw-" + precision["dtype"]] = {
            "processRSS": fit(
                windows,
                [r["search"]["afterOpen"]["rss"] / 1024**2 for r in rows],
                "MiB",
            ),
            "graphDisk": fit(
                windows, [r["build"]["dbBytes"] / 1e6 for r in rows], "MB"
            ),
        }
    rows = [r for r in native["search"] if r["limit"] == 100]
    assert len(rows) == 10
    result["engines"]["native-exhaustive"] = {
        "processRSS": fit(
            [r["windows"] for r in rows], [r["finalRSS"] / 1024**2 for r in rows], "MiB"
        )
    }
    rows = sqlite["scales"]
    assert len(rows) == 10 and all(
        "final" in r["diskann"] and "final" in r["exact"] for r in rows
    )
    windows = [r["windows"] for r in rows]
    for engine, build in [("diskann", "build"), ("exact", "exactBuild")]:
        result["engines"]["sqlite-" + engine] = {
            "processRSS": fit(
                windows, [r[engine]["final"]["rss"] / 1024**2 for r in rows], "MiB"
            ),
            "indexDisk": fit(windows, [r[build]["dbBytes"] / 1e6 for r in rows], "MB"),
        }
    (a.directory / "growth_measurements.json").write_text(
        json.dumps(result, indent=2) + "\n"
    )


if __name__ == "__main__":
    main()
