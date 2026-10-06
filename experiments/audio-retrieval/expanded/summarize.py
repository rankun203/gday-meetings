"""Summarize the expanded comparison, paired uncertainty and measured resources."""

import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from summarize import clustered_interval

METHODS = [
    ("clsp-audio", "Audio", "CLSP"),
    ("clap-audio-max", "Audio", "CLAP · maximum"),
    ("clap-audio-mean", "Audio", "CLAP · mean"),
    ("jina-audio", "Audio", "Jina"),
    ("bm25", "Transcript", "BM25"),
    ("word-tfidf", "Transcript", "Word TF-IDF"),
    ("character-tfidf", "Transcript", "Character TF-IDF"),
    ("e5-transcript", "Transcript", "E5 small"),
    ("jina-transcript", "Transcript", "Jina"),
    ("granite-97m", "Transcript", "Granite 97M"),
    ("granite-311m", "Transcript", "Granite 311M"),
    ("harrier-270m", "Transcript", "Harrier 270M"),
    ("harrier-600m", "Transcript", "Harrier 0.6B"),
    ("qwen3-600m", "Transcript", "Qwen3 0.6B"),
    ("hybrid-e5-bm25", "Transcript", "E5 + BM25"),
    ("hybrid-jina-transcript-bm25", "Transcript", "Jina + BM25"),
    ("hybrid-jina-audio-bm25", "Audio + transcript", "Jina audio + BM25"),
    (
        "hybrid-jina-audio-transcript",
        "Audio + transcript",
        "Jina audio + Jina transcript",
    ),
]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("dataset", type=Path)
    ap.add_argument("runs", type=Path)
    ap.add_argument("comparison", type=Path)
    args = ap.parse_args()
    qs = [
        json.loads(s) for s in (args.dataset / "queries.jsonl").read_text().splitlines()
    ]
    cs = [
        json.loads(s) for s in (args.dataset / "corpus.jsonl").read_text().splitlines()
    ]
    metrics = json.loads((args.comparison / "metrics.json").read_text())
    per = json.loads((args.comparison / "per-query-evidence.json").read_text())
    relevance = json.loads((args.comparison / "per-query-relevance.json").read_text())
    intervals = {}
    for cohort in ["all", "original", "human_reviewed", "decision_challenge"]:
        idx = [i for i, q in enumerate(qs) if cohort == "all" or q["cohort"] == cohort]
        cluster = [qs[i]["scenario_id"] for i in idx]
        intervals[cohort] = {}
        for metric, source in [
            ("hit@1", per),
            ("hit@10", per),
            ("mrr", per),
            ("useful@1", relevance),
            ("full_support@1", relevance),
        ]:
            values = [
                source["granite-311m"][i][metric] - source["jina-transcript"][i][metric]
                for i in idx
            ]
            intervals[cohort][metric] = clustered_interval(values, cluster)
    resources = {}
    for name in [
        "jina-text-only",
        "granite-97m",
        "granite-311m",
        "harrier-270m",
        "harrier-600m",
        "qwen3-600m",
        "e5",
        "jina",
        "clap",
        "clsp",
    ]:
        folder = args.runs / name
        info = json.loads((folder / "complete.json").read_text())
        for kind in ["query", "transcript", "audio"]:
            files = list(folder.glob(kind + "-*.npz"))
            if files:
                seconds = [float(np.load(p)["seconds"]) for p in files]
                info[kind] = {
                    "count": len(files),
                    "median_ms": float(np.median(seconds) * 1000),
                    "p95_ms": float(np.quantile(seconds, 0.95) * 1000),
                    "total_seconds": float(sum(seconds)),
                    "items_per_second": len(files) / sum(seconds),
                }
        resources[name] = info
    summary = {
        "queries": len(qs),
        "windows": len(cs),
        "gallery_scenarios": len({c["scenario_id"] for c in cs}),
        "query_scenarios": len({q["scenario_id"] for q in qs}),
        "intervals_granite_minus_jina": intervals,
        "resources": resources,
        "metrics": metrics,
        "duration_seconds": sum(c["duration_s"] for c in cs),
    }
    (args.comparison / "expanded-summary.json").write_text(
        json.dumps(summary, indent=2)
    )
    lines = [
        "| Input | Method | Evidence @1 | @5 | @10 | MRR | Useful @1 | Full support @1 |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    pct = lambda value: f"{value * 100:.1f}%"
    for name, kind, label in METHODS:
        e = metrics["evidence"][name]["all"]
        r = metrics["relevance"][name]["all"]
        lines.append(
            f"| {kind} | {label} | {pct(e['hit@1'])} | {pct(e['hit@5'])} | {pct(e['hit@10'])} | {e['mrr']:.3f} | {pct(r['useful@1'])} | {pct(r['full_support@1'])} |"
        )
    (args.comparison / "matrix.md").write_text(
        "---\ntitle: Expanded comparison matrix\ndate: 2026-10-06\nstatus: generated\n---\n\n"
        + "\n".join(lines)
        + "\n"
    )
    print(
        json.dumps(
            {
                "queries": len(qs),
                "windows": len(cs),
                "scenarios": summary["query_scenarios"],
                "methods": len(METHODS),
            }
        )
    )


if __name__ == "__main__":
    main()
