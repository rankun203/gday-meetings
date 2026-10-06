"""Score paired transcript variants against unchanged expanded-gallery labels."""

import argparse
import hashlib
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from compare import bm25, evidence_metrics, order_scores, rrf


def read(path):
    return [json.loads(s) for s in path.read_text().splitlines()]


def summarize_support(pool, pool_key, judgments, query_count):
    by_id = {j["review_id"]: j for j in judgments}
    if len(by_id) != len(judgments) or set(by_id) != set(pool):
        raise ValueError("Judgments must cover the complete variant pool exactly once")
    if any(
        j["grade"] not in [0, 1, 2, 3]
        or j["support"]
        not in {"full", "partial", "question_only", "none", "contradiction"}
        or not j.get("reason", "").strip()
        for j in judgments
    ):
        raise ValueError("Invalid variant judgment")
    result = {}
    for condition in sorted({k["condition"] for k in pool_key}):
        result[condition] = {}
        for method in sorted({k["method"] for k in pool_key}):
            items = [
                by_id[k["review_id"]]
                for k in pool_key
                if k["condition"] == condition and k["method"] == method
            ]
            result[condition][method] = {
                "useful@1": sum(j["grade"] >= 2 for j in items) / query_count,
                "full_support@1": sum(j["support"] == "full" for j in items)
                / query_count,
                "returned": len(items),
                "queries": query_count,
            }
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("dataset", type=Path)
    ap.add_argument("runs", type=Path)
    ap.add_argument("variants", type=Path)
    ap.add_argument("output", type=Path)
    ap.add_argument(
        "--judgments", type=Path, help="Score a complete first-result review pool."
    )
    a = ap.parse_args()
    original = read(a.dataset / "corpus.jsonl")
    queries = read(a.dataset / "queries.jsonl")
    qids = [q["query_id"] for q in queries]
    cids = [c["segment_id"] for c in original]
    lookup = {c: i for i, c in enumerate(cids)}
    positives = [{lookup[p["window_id"]] for p in q["positives"]} for q in queries]
    iq = np.concatenate(
        [np.load(a.runs / "jina" / f"query-{key}.npz")["embedding"] for key in qids]
    )
    ia = np.concatenate(
        [np.load(a.runs / "jina" / f"audio-{key}.npz")["embedding"] for key in cids]
    )
    audio_ranks = order_scores(iq @ ia.T, cids)
    summary = {}
    details = {}
    rankings = {}
    pool, pool_key = {}, []
    for condition in ["apple", "imported", "whisperx", "review-patched-apple"]:
        dataset = a.dataset if condition == "apple" else a.variants / condition
        corpus = read(dataset / "corpus.jsonl")
        assert (dataset / "queries.jsonl").read_bytes() == (
            a.dataset / "queries.jsonl"
        ).read_bytes()
        assert [(c["segment_id"], c["audio_path"]) for c in corpus] == [
            (c["segment_id"], c["audio_path"]) for c in original
        ]
        digest = hashlib.sha256()
        for name in ["queries.jsonl", "corpus.jsonl"]:
            digest.update((dataset / name).read_bytes())
        for c in corpus:
            digest.update(Path(c["audio_path"]).read_bytes())
        scores = {
            "bm25": bm25(
                [q["query"] for q in queries],
                [c["transcript_evidence"] for c in corpus],
            )
        }
        for model in ["jina-text-only", "granite-311m", "qwen3-600m"]:
            folder = (a.runs if condition == "apple" else dataset / "runs") / model
            assert (
                json.loads((folder / "manifest.json").read_text())["inputs_sha256"]
                == digest.hexdigest()
            )
            q = np.concatenate(
                [np.load(folder / f"query-{key}.npz")["embedding"] for key in qids]
            )
            c = np.concatenate(
                [np.load(folder / f"transcript-{key}.npz")["embedding"] for key in cids]
            )
            scores[model] = q @ c.T
        orders = {
            name: order_scores(score, cids, name == "bm25")
            for name, score in scores.items()
        }
        orders["jina-audio-transcript"] = order_scores(
            rrf([audio_ranks, orders["jina-text-only"]], len(cids)), cids
        )
        details[condition] = {}
        summary[condition] = {}
        rankings[condition] = {}
        for name, order in orders.items():
            for qi, query in enumerate(queries):
                if query["cohort"] != "human_reviewed" or not order[qi]:
                    continue
                di = order[qi][0]
                passage = corpus[di]["transcript_evidence"]
                token_input = f"review-v1:{query['query_id']}:{cids[di]}"
                if passage != original[di]["transcript_evidence"]:
                    token_input += ":" + hashlib.sha256(passage.encode()).hexdigest()
                token = hashlib.sha256(token_input.encode()).hexdigest()[:16]
                pool[token] = {
                    "review_id": token,
                    "query": query["query"],
                    "passage": passage,
                    "reference_evidence": [
                        p.get("transcript_evidence", "") for p in query["positives"]
                    ],
                }
                pool_key.append(
                    {
                        "review_id": token,
                        "condition": condition,
                        "method": name,
                        "query_id": query["query_id"],
                    }
                )
            values = [
                evidence_metrics(row, positive)
                for row, positive in zip(order, positives)
            ]
            details[condition][name] = values
            rankings[condition][name] = {
                q["query_id"]: [cids[i] for i in row[:10]]
                for q, row in zip(queries, order)
            }
            summary[condition][name] = {}
            for group in ["all", "human_reviewed", "decision_challenge", "original"]:
                indices = [
                    i
                    for i, q in enumerate(queries)
                    if group == "all" or q["cohort"] == group
                ]
                summary[condition][name][group] = {
                    k: float(np.mean([values[i][k] for i in indices]))
                    for k in values[0]
                }
        summary[condition]["empty_new_windows"] = sum(
            not c["transcript_evidence"] for c in corpus if "recording_id" in c
        )
    a.output.mkdir(parents=True, exist_ok=False)
    (a.output / "blind-pool.jsonl").write_text(
        "".join(json.dumps(pool[k], ensure_ascii=False) + "\n" for k in sorted(pool))
    )
    (a.output / "pool-key.json").write_text(json.dumps(pool_key, indent=2))
    for name, data in [
        ("metrics", summary),
        ("per-query", details),
        ("rankings", rankings),
    ]:
        (a.output / (name + ".json")).write_text(json.dumps(data, indent=2))
    if a.judgments:
        support = summarize_support(
            pool,
            pool_key,
            read(a.judgments),
            sum(q["cohort"] == "human_reviewed" for q in queries),
        )
        (a.output / "relevance-summary.json").write_text(json.dumps(support, indent=2))
    print(
        json.dumps(
            {
                c: {
                    m: v["human_reviewed"]["hit@1"]
                    for m, v in s.items()
                    if isinstance(v, dict)
                }
                for c, s in summary.items()
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
