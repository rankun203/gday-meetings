"""Check CPU/Metal text embeddings against an unchanged subset of the corpus."""

import argparse
import json
from pathlib import Path

import numpy as np
from encode_text import MODELS


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dataset", type=Path)
    parser.add_argument("probe_dataset", type=Path)
    parser.add_argument("runs", type=Path)
    args = parser.parse_args()
    result = {}
    for name in MODELS:
        cpu = args.runs / "cpu-parity" / name
        metal = args.runs / name
        if not (cpu / "complete.json").exists() or not (metal / "complete.json").exists():
            raise ValueError("Every selected model needs complete CPU and Metal runs.")
        cpu_manifest = json.loads((cpu / "manifest.json").read_text())
        metal_manifest = json.loads((metal / "manifest.json").read_text())
        if cpu_manifest["device"] != "cpu" or metal_manifest["device"] != "mps":
            raise ValueError("Expected a CPU probe and a Metal reference.")
        for key in ["model", "revision", "dtype", "instruction", "pooling", "runner_sha256", "versions"]:
            if cpu_manifest[key] != metal_manifest[key]:
                raise ValueError(f"CPU and Metal runs differ in {key}.")
        cosines, differences = [], []
        for filename, kind, key in [("queries.jsonl", "query", "query_id"),
                                    ("corpus.jsonl", "transcript", "segment_id")]:
            full = {row[key]: row for row in map(json.loads, (args.dataset / filename).read_text().splitlines())}
            for row in map(json.loads, (args.probe_dataset / filename).read_text().splitlines()):
                if row != full[row[key]]:
                    raise ValueError("Probe input differs from the full benchmark input.")
                a = np.load(cpu / f"{kind}-{row[key]}.npz")["embedding"].astype(np.float64)
                b = np.load(metal / f"{kind}-{row[key]}.npz")["embedding"].astype(np.float64)
                if a.shape != b.shape or not np.isfinite(a).all() or not np.isfinite(b).all():
                    raise ValueError("Probe embeddings must have matching shapes and finite values.")
                if not np.allclose([np.linalg.norm(a), np.linalg.norm(b)], 1, atol=1e-4):
                    raise ValueError("Probe embeddings must be normalized.")
                cosines.append(float(np.sum(a * b) / (np.linalg.norm(a) * np.linalg.norm(b))))
                differences.append(float(np.max(np.abs(a - b))))
        if not cosines or min(cosines) < 0.99999 or max(differences) > 1e-4:
            raise ValueError(f"CPU/Metal agreement failed for {name}.")
        result[name] = {"probes": len(cosines), "minimum_cosine": min(cosines),
                        "maximum_absolute_difference": max(differences)}
    (args.runs / "cpu-metal-parity.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
