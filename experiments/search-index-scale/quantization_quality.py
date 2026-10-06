"""Reuse labeled retrieval inputs to separate vector compression from ANN loss."""

import argparse
import json
from pathlib import Path

import numpy as np
import usearch
from usearch.index import Index


def normalized(path):
    payload = json.loads(path.read_text())
    assert payload["nonfiniteValues"] == 0
    vectors = np.asarray(payload["vectors"], dtype="f4")
    return vectors / np.linalg.norm(vectors, axis=1, keepdims=True)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--dataset", type=Path, required=True)
    p.add_argument("--queries", type=Path, required=True)
    p.add_argument("--documents", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    a = p.parse_args()
    queries = [
        json.loads(line)
        for line in (a.dataset / "queries.jsonl").read_text().splitlines()
    ]
    corpus = [
        json.loads(line)
        for line in (a.dataset / "corpus.jsonl").read_text().splitlines()
    ]
    q = normalized(a.queries)
    v = normalized(a.documents)
    assert len(q) == len(queries)
    if len(v) == len(queries) + len(corpus):
        v = v[len(queries) :]
    assert len(v) == len(corpus) and v.shape[1] == 384
    lookup = {row["segment_id"]: i for i, row in enumerate(corpus)}
    positives = [
        {lookup[x["window_id"]] for x in query["positives"]} for query in queries
    ]
    scores = q @ v.T
    reference = np.argsort(-scores, axis=1, kind="stable")

    def metrics(ranks):
        return {
            "byLimit": {
                str(limit): {
                    "hit": float(
                        np.mean(
                            [
                                bool(set(r[:limit]) & pos)
                                for r, pos in zip(ranks, positives)
                            ]
                        )
                    ),
                    "evidenceRecall": float(
                        np.mean(
                            [
                                len(set(r[:limit]) & pos) / len(pos)
                                for r, pos in zip(ranks, positives)
                            ]
                        )
                    ),
                    "overlap": float(
                        np.mean(
                            [
                                len(set(r[:limit]) & set(b[:limit])) / limit
                                for r, b in zip(ranks, reference)
                            ]
                        )
                    ),
                    "scoreEquivalentOverlap": float(
                        np.mean(
                            [
                                np.mean(
                                    scores[qi, np.asarray(r[:limit])]
                                    >= scores[qi, reference[qi, limit - 1]] - 1e-6
                                )
                                for qi, r in enumerate(ranks)
                            ]
                        )
                    ),
                }
                for limit in [10, 20, 50, 100]
                if min(map(len, ranks)) >= limit
            },
            "hitAt1": float(np.mean([r[0] in pos for r, pos in zip(ranks, positives)])),
            "hitAt5": float(
                np.mean([bool(set(r[:5]) & pos) for r, pos in zip(ranks, positives)])
            ),
            "evidenceRecallAt5": float(
                np.mean(
                    [
                        len(set(r[:5]) & pos) / len(pos)
                        for r, pos in zip(ranks, positives)
                    ]
                )
            ),
            "MRR": float(
                np.mean(
                    [
                        next((1 / (i + 1) for i, key in enumerate(r) if key in pos), 0)
                        for r, pos in zip(ranks, positives)
                    ]
                )
            ),
            "top1Agreement": float(
                np.mean([r[0] == b[0] for r, b in zip(ranks, reference)])
            ),
            "top5Overlap": float(
                np.mean(
                    [len(set(r[:5]) & set(b[:5])) / 5 for r, b in zip(ranks, reference)]
                )
            ),
        }

    output = {
        "version": usearch.__version__,
        "dimensions": 384,
        "queries": len(q),
        "passages": len(v),
        "scoreEquivalentTolerance": 1e-6,
        "baseline": metrics(reference),
        "cases": [],
    }
    for dtype in ["f32", "f16", "i8"]:
        index = Index(
            ndim=384, metric="cos", dtype=dtype, connectivity=32, expansion_add=128
        )
        index.add(np.arange(len(v), dtype=np.uint64), v, threads=1)
        # Exhaustive traversal over compressed stored vectors isolates compression
        # quality from approximate candidate retrieval.
        exact = [
            index.search(query, count=len(v), exact=True, threads=1).keys.tolist()
            for query in q
        ]
        output["cases"].append(
            {
                "dtype": dtype,
                "method": "compressed-exhaustive",
                "hardware": index.hardware_acceleration,
                **metrics(exact),
            }
        )
        for candidates in [10, 20, 50, 100, 200, 800, 1000]:
            index.expansion_search = max(128, 2 * candidates)
            for rerank in [False, True]:
                ranks = []
                for query in q:
                    matches = index.search(
                        query, count=min(candidates, len(v)), threads=1
                    )
                    ids = np.asarray(matches.keys, dtype=np.int64)
                    values = (
                        v[ids] @ query if rerank else 1 - np.asarray(matches.distances)
                    )
                    ranks.append(ids[np.lexsort((ids, -values))].tolist())
                output["cases"].append(
                    {
                        "dtype": dtype,
                        "method": "hnsw",
                        "candidates": candidates,
                        "fp32Rerank": rerank,
                        **metrics(ranks),
                    }
                )
    a.output.write_text(json.dumps(output, indent=2) + "\n")
    print(json.dumps(output))


if __name__ == "__main__":
    main()
