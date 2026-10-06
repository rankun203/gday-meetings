"""Summarize resource observations and paired evidence changes for text runs."""

import argparse
import json
from pathlib import Path

import numpy as np
from encode_text import MODELS
from summarize import clustered_interval


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dataset", type=Path)
    parser.add_argument("runs", type=Path)
    args = parser.parse_args()
    queries = [json.loads(line) for line in (args.dataset / "queries.jsonl").read_text().splitlines()]
    clusters = [q["scenario_id"] for q in queries]
    evidence = json.loads((args.runs / "per-query-evidence.json").read_text())
    resources, differences = {}, {}
    for name in MODELS:
        folder = args.runs / name
        if not (folder / "complete.json").exists():
            continue
        resources[name] = json.loads((folder / "complete.json").read_text())
        for kind in ["query", "transcript"]:
            seconds, token_counts = [], []
            for path in folder.glob(f"{kind}-*.npz"):
                with np.load(path) as value:
                    seconds.append(float(value["seconds"]))
                    token_counts.append(int(value["tokens"]))
            resources[name][kind] = {
                "count": len(seconds), "median_seconds": float(np.median(seconds)),
                "p95_seconds": float(np.quantile(seconds, 0.95)),
                "total_seconds": sum(seconds), "items_per_second": len(seconds) / sum(seconds),
                "max_tokens": max(token_counts),
            }
        differences[name] = {
            metric: clustered_interval([a[metric] - b[metric] for a, b in
                    zip(evidence[name], evidence["jina-transcript"])], clusters)
            for metric in ["hit@1", "hit@10", "mrr"]
        }
    matrices = np.load(args.runs / "scores.npz")
    parity = {}
    if "jina-text-only" in matrices:
        parity["maximum_score_difference"] = float(np.max(np.abs(matrices["jina-text-only"] - matrices["jina-transcript"])))
        rankings = json.loads((args.runs / "rankings.json").read_text())
        parity["identical_complete_rankings"] = sum(rankings["jina-text-only"][qid] == ranking
            for qid, ranking in rankings["jina-transcript"].items())
    result = {"resources": resources, "paired_differences_from_original_jina": differences,
              "jina_text_only_parity": parity}
    (args.runs / "text-summary.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"models": list(resources), "jina_text_only_parity": parity}))


if __name__ == "__main__":
    main()
