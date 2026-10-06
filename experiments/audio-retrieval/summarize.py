"""Summarize scenario-clustered uncertainty and independently entered pair judgments."""

import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path

import numpy as np


def clustered_interval(differences, clusters, seed=42, repetitions=10000):
    """Resample whole scenarios, retaining every query within the sampled scenario."""
    names = sorted(set(clusters))
    groups = [np.flatnonzero(np.asarray(clusters) == name) for name in names]
    rng = np.random.default_rng(seed)
    values = np.array([np.mean(np.asarray(differences)[np.concatenate([groups[i] for i in sample])])
                       for sample in rng.integers(len(groups), size=(repetitions, len(groups)))])
    return {"difference": float(np.mean(differences)), "ci95": np.quantile(values, [0.025, 0.975]).tolist(),
            "clusters": len(groups), "bootstrap_repetitions": repetitions, "seed": seed}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dataset", type=Path)
    parser.add_argument("runs", type=Path)
    args = parser.parse_args()
    qs = [json.loads(x) for x in (args.dataset / "queries.jsonl").read_text().splitlines()]
    clusters = [q["scenario_id"] for q in qs]
    evidence = json.loads((args.runs / "per-query-evidence.json").read_text())
    relevance = json.loads((args.runs / "per-query-relevance.json").read_text())
    intervals = {}
    for first, second in [("jina-audio", "clsp-audio"), ("jina-audio", "bm25"),
                          ("jina-transcript", "e5-transcript"), ("jina-transcript", "bm25"),
                          ("hybrid-jina-audio-bm25", "jina-audio"),
                          ("hybrid-jina-transcript-bm25", "jina-transcript")]:
        intervals[first + " minus " + second] = {}
        for metric, source in [("hit@10", evidence), ("useful@1", relevance), ("pooled_ndcg@5", relevance)]:
            intervals[first + " minus " + second][metric] = clustered_interval(
                [a[metric] - b[metric] for a, b in zip(source[first], source[second])], clusters)
    keys = json.loads((args.runs / "pair-key.json").read_text())
    judgments = {x["id"]: x for x in json.loads((args.runs / "pair-judgments.json").read_text())}
    if set(judgments) != {x["id"] for x in keys}:
        raise ValueError("Pairwise judgments do not cover the complete comparison set.")
    pair_results = defaultdict(Counter)
    canonical = {}
    for item in keys:
        verdict = judgments[item["id"]]["verdict"]
        if verdict not in {"A", "B", "tie", "both_irrelevant"}:
            raise ValueError("Unknown pairwise verdict.")
        winner = item["methods"][0 if verdict == "A" else 1] if verdict in {"A", "B"} else verdict
        canonical[(item["query_id"], tuple(item["comparison"]), item["repeat"])] = winner
        if not item["repeat"]:
            pair_results[" versus ".join(item["comparison"])][winner] += 1
    repeats = [k for k in canonical if k[2]]
    consistency = sum(canonical[k] == canonical[(k[0], k[1], False)] for k in repeats)
    result = {"paired_cluster_bootstrap": intervals, "pairwise": pair_results,
              "order_reversal": {"consistent": consistency, "repeated": len(repeats)},
              "limits": "Exploratory percentile intervals across 10 selected scenarios, not population guarantees or multiple-comparison-adjusted tests. Pairwise repeats use the same judge and are not independent assessments."}
    (args.runs / "uncertainty-and-pairs.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
