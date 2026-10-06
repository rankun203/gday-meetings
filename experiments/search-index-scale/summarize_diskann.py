"""Export aggregate benchmark receipts; never copy vectors or reference IDs."""

import argparse
import json
from pathlib import Path

import numpy as np


def aggregate(value):
    """Retain the full factor grid while dropping individual observations."""
    observations = value.pop("observations", [])
    value.pop("timesMs", None)
    if observations:
        cells = value.setdefault("byLength", {})
        for label in dict.fromkeys(row["label"] for row in observations):
            rows = [row for row in observations if row["label"] == label]
            cell = cells.setdefault(label, {})
            cell.update(
                {
                    "samples": len(rows),
                    "p50Ms": float(np.median([row["milliseconds"] for row in rows])),
                    "p95Ms": float(
                        np.percentile([row["milliseconds"] for row in rows], 95)
                    ),
                    "maxRSS": max(row["rss"] for row in rows),
                    "maxPhysicalFootprint": max(
                        row["physicalFootprint"] for row in rows
                    ),
                    **{
                        key: sum(row[key] for row in rows)
                        for key in ["cpuSeconds", "readBytes", "writtenBytes"]
                    },
                    "rankingByLimit": {
                        limit: {
                            key: float(
                                np.mean(
                                    [row["rankingByLimit"][limit][key] for row in rows]
                                )
                            )
                            for key in metrics
                        }
                        for limit, metrics in rows[0].get("rankingByLimit", {}).items()
                    },
                }
            )
    for case in value.get("cases", []):
        aggregate(case)
    return value


def main():
    p = argparse.ArgumentParser()
    p.add_argument("run", type=Path)
    p.add_argument("output", type=Path)
    a = p.parse_args()
    result = {
        "schemaVersion": 2,
        "extension": "sqlite-vec 0.1.10-alpha.4",
        "scales": [],
    }
    for scale in range(1, 11):
        cell = {"scale": scale, "windows": scale * 39066}
        for key, name in {
            "build": f"build-{scale}.json",
            "exactBuild": f"exact-build-{scale}.json",
            "diskann": f"diskann-search-{scale}.json",
            "exact": f"exact-search-{scale}.json",
            "hybrid": f"hybrid-{scale}-200.json",
            "diskannMutations": f"mutations-{scale}/diskann-mutations-{scale}.json",
            "exactMutations": f"mutations-{scale}/exact-mutations-{scale}.json",
        }.items():
            path = a.run / name
            cell[key] = (
                aggregate(json.loads(path.read_text()))
                if path.exists()
                else {"status": "pending"}
            )
        result["scales"].append(cell)
    query = a.run / "query-length-timings.json"
    if query.exists():
        result["queryLength"] = json.loads(query.read_text())
    a.output.write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()
