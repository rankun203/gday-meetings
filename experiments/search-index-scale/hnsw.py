"""USearch HNSW precision/scale grid. Inputs and generated indexes stay ignored."""

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import usearch
from diskann import TOP, D, rank, resources, save, score_recall
from mutations import clone
from usearch.index import Index


def open_index(a, load=True):
    index = Index(
        ndim=D,
        metric="cos",
        dtype=a.dtype,
        connectivity=32,
        expansion_add=128,
        expansion_search=128,
    )
    if index.hardware_acceleration == "serial":
        raise RuntimeError(
            "CPU feature detection returned serial; run with native feature access"
        )
    if load and (a.output / "graph.bin").exists():
        index.load(str(a.output / "graph.bin"))
    return index


def delta(before, after):
    return {
        key: after[key] - before[key]
        for key in ["cpuSeconds", "readBytes", "writtenBytes"]
    }


def summary(rows):
    return {
        "samples": len(rows),
        "p50Ms": float(np.median([r["milliseconds"] for r in rows])),
        "p95Ms": float(np.percentile([r["milliseconds"] for r in rows], 95)),
        "rankingByLimit": {
            limit: {
                key: float(np.mean([row["rankingByLimit"][limit][key] for row in rows]))
                for key in ["contentRecall", "boostedRecall", "filteredRecall"]
            }
            for limit in rows[0].get("rankingByLimit", {})
        },
        **{
            key: float(np.mean([r[key] for r in rows]))
            for key in [
                "contentRecall",
                "boostedRecall",
                "filteredRecall",
                "contentScoreRecall",
                "boostedScoreRecall",
                "filteredScoreRecall",
            ]
        },
    }


def measure(a):
    n = 39066 * a.scale
    before = resources()
    start = time.perf_counter()
    index = open_index(a)
    report = {
        "engine": "usearch-hnsw",
        "dtype": a.dtype,
        "version": usearch.__version__,
        "scale": a.scale,
        "windows": n,
        "openMs": (time.perf_counter() - start) * 1000,
        "baseline": before,
        "afterOpen": resources(),
        "hardware": index.hardware_acceleration,
        "cases": [],
    }
    queries = np.load(a.run / "queries.npy")
    labels = json.loads((a.run / "query-labels.json").read_text())
    refs = json.loads((a.run / f"truth-{a.scale}.json").read_text())
    refs100 = json.loads((a.run / f"truth100-{a.scale}.json").read_text())
    # Original vectors remain on disk. pread fetches only selected candidates;
    # this avoids making the original FP32 corpus a second resident graph.
    import os

    fd = os.open(a.run / "all.f32", os.O_RDONLY)
    for candidates in [10, 20, 50, 100, 200, 800, 1000]:
        index.expansion_search = max(128, candidates * 2)
        for rerank in [False, True]:
            observations = []
            for repeat in range(3):
                for qi, q in enumerate(queries):
                    before = resources()
                    start = time.perf_counter()
                    matches = index.search(q, count=candidates, threads=1)
                    ids = np.asarray(matches.keys, dtype=np.int64)
                    scores = 1 - np.asarray(matches.distances)
                    if rerank:
                        vectors = np.stack(
                            [
                                np.frombuffer(
                                    os.pread(fd, D * 4, (int(i) - 1) * D * 4),
                                    dtype="<f4",
                                )
                                for i in ids
                            ]
                        )
                        scores = (
                            vectors
                            @ q
                            / (np.linalg.norm(vectors, axis=1) * np.linalg.norm(q))
                        )
                    boosted = scores + 0.1 * ((ids // 107) % 97 == qi % 97)
                    allowed = ids % 5 == 0
                    full_ranks = [
                        rank(ids, scores, top=100),
                        rank(ids, boosted, top=100),
                        rank(ids[allowed], scores[allowed], top=100),
                    ]
                    ranks = [values[:TOP] for values in full_ranks]
                    elapsed = (time.perf_counter() - start) * 1000
                    after = resources()
                    ref = refs[qi]
                    observations.append(
                        {
                            "query": qi,
                            "repeat": repeat,
                            "label": labels[qi],
                            "milliseconds": elapsed,
                            "rss": after["rss"],
                            "peakRSS": after["peakRSS"],
                            "physicalFootprint": after["physicalFootprint"],
                            **delta(before, after),
                            "rankingByLimit": {
                                str(limit): {
                                    key: len(
                                        set(got[:limit])
                                        & set(refs100[qi][reference][:limit])
                                    )
                                    / limit
                                    for key, got, reference in zip(
                                        [
                                            "contentRecall",
                                            "boostedRecall",
                                            "filteredRecall",
                                        ],
                                        full_ranks,
                                        ["plain", "boost", "filtered"],
                                    )
                                }
                                for limit in [10, 20, 50, 100]
                                if candidates >= limit
                            },
                            **{
                                key: len(set(got) & set(ref[truth])) / TOP
                                for key, got, truth in zip(
                                    [
                                        "contentRecall",
                                        "boostedRecall",
                                        "filteredRecall",
                                    ],
                                    ranks,
                                    ["plain", "boost", "filtered"],
                                )
                            },
                            **{
                                key: score_recall(values, ref[truth])
                                for key, values, truth in zip(
                                    [
                                        "contentScoreRecall",
                                        "boostedScoreRecall",
                                        "filteredScoreRecall",
                                    ],
                                    [scores, boosted, scores[allowed]],
                                    ["plainScores", "boostScores", "filteredScores"],
                                )
                            },
                        }
                    )
            report["cases"].append(
                {
                    "candidates": candidates,
                    "efSearch": index.expansion_search,
                    "fp32Rerank": rerank,
                    "firstMs": observations[0]["milliseconds"],
                    **summary(observations),
                    "byLength": {
                        label: summary([r for r in observations if r["label"] == label])
                        for label in dict.fromkeys(labels)
                    },
                    "observations": observations,
                }
            )
            save(a.output / f"hnsw-search-{a.scale}.json", report)
    os.close(fd)
    report["final"] = resources()
    save(a.output / f"hnsw-search-{a.scale}.json", report)
    print(
        json.dumps(
            {
                "event": "search",
                "dtype": a.dtype,
                "scale": a.scale,
                "openMs": report["openMs"],
                "cases": [
                    {
                        k: v
                        for k, v in case.items()
                        if k
                        in [
                            "candidates",
                            "fp32Rerank",
                            "p50Ms",
                            "contentRecall",
                            "boostedRecall",
                        ]
                    }
                    for case in report["cases"]
                ],
            }
        ),
        flush=True,
    )


def stage(a):
    n = 39066 * a.scale
    index = open_index(a, load=a.scale > 1)
    with (a.run / "all.f32").open("rb") as f:
        f.seek((n - 39066) * D * 4)
        block = np.frombuffer(f.read(39066 * D * 4), dtype="<f4").reshape(-1, D)
    before = resources()
    start = time.perf_counter()
    index.add(np.arange(n - 39066 + 1, n + 1, dtype=np.uint64), block, threads=1)
    built = time.perf_counter() - start
    start = time.perf_counter()
    index.save(str(a.output / "graph.bin"))
    persisted = time.perf_counter() - start
    report = {
        "engine": "usearch-hnsw",
        "dtype": a.dtype,
        "scale": a.scale,
        "windows": n,
        "seconds": built,
        "persistSeconds": persisted,
        "before": before,
        "after": resources(),
        "dbBytes": (a.output / "graph.bin").stat().st_size,
        "hardware": index.hardware_acceleration,
    }
    save(a.output / f"hnsw-build-{a.scale}.json", report)
    # Retain a copy-on-write stage snapshot for additional query settings without
    # rebuilding earlier graphs. Snapshot copying is outside build measurements.
    clone(a.output / "graph.bin", a.output / "snapshots" / f"graph-{a.scale}.bin")
    print(
        json.dumps({k: v for k, v in report.items() if k not in ["before", "after"]}),
        flush=True,
    )


def hybrid(a):
    """Content candidates plus exact scoring of all identified-speaker vectors."""
    import os
    import sqlite3

    n = 39066 * a.scale
    metadata = a.output / "people.db"
    c = sqlite3.connect(metadata)
    c.execute("pragma cache_size=-2048")
    c.execute("pragma mmap_size=0")
    c.execute(
        "create table if not exists speakers(id integer primary key, person integer not null)"
    )
    c.execute("create index if not exists speakers_person on speakers(person)")
    previous = c.execute("select coalesce(max(id),0) from speakers").fetchone()[0]
    started = time.perf_counter()
    c.executemany(
        "insert into speakers values (?,?)",
        ((i, (i // 107) % 97) for i in range(previous + 1, n + 1)),
    )
    c.commit()
    metadata_seconds = time.perf_counter() - started
    index = open_index(a)
    index.expansion_search = 2000
    queries = np.load(a.run / "queries.npy")
    labels = json.loads((a.run / "query-labels.json").read_text())
    references = json.loads((a.run / f"truth100-{a.scale}.json").read_text())
    fd = os.open(a.run / "all.f32", os.O_RDONLY)
    observations = []
    before_all = resources()
    for qi, q in enumerate(queries):
        before = resources()
        started = time.perf_counter()
        matches = index.search(q, count=1000, threads=1)
        speaker_ids = [
            r[0]
            for r in c.execute(
                "select id from speakers where person=? and id<=?", (qi % 97, n)
            )
        ]
        ids = np.unique(
            np.concatenate(
                [
                    np.asarray(matches.keys, dtype=np.int64),
                    np.asarray(speaker_ids, dtype=np.int64),
                ]
            )
        )
        vectors = np.stack(
            [
                np.frombuffer(os.pread(fd, D * 4, (int(i) - 1) * D * 4), dtype="<f4")
                for i in ids
            ]
        )
        scores = vectors @ q / (np.linalg.norm(vectors, axis=1) * np.linalg.norm(q))
        scores += 0.1 * ((ids // 107) % 97 == qi % 97)
        ranked = rank(ids, scores, top=100)
        elapsed = (time.perf_counter() - started) * 1000
        after = resources()
        observations.append(
            {
                "query": qi,
                "label": labels[qi],
                "milliseconds": elapsed,
                "speakerWindows": len(speaker_ids),
                "unionWindows": len(ids),
                "rss": after["rss"],
                "physicalFootprint": after["physicalFootprint"],
                **delta(before, after),
                "rankingByLimit": {
                    str(k): {
                        "boostedRecall": len(
                            set(ranked[:k]) & set(references[qi]["boost"][:k])
                        )
                        / k,
                        "boostedScoreRecall": score_recall(
                            scores, references[qi]["boostScores"][:k], top=k
                        ),
                    }
                    for k in [5, 10, 20, 50, 100]
                },
            }
        )
    report = {
        "engine": "usearch-hnsw",
        "dtype": a.dtype,
        "scale": a.scale,
        "windows": n,
        "candidates": 1000,
        "strategy": "content ANN union exact identified-speaker windows",
        "metadataBuildSeconds": metadata_seconds,
        "metadataBytes": metadata.stat().st_size,
        "before": before_all,
        "after": resources(),
        "firstMs": observations[0]["milliseconds"],
        "p50Ms": float(np.median([r["milliseconds"] for r in observations[1:]])),
        "p95Ms": float(
            np.percentile([r["milliseconds"] for r in observations[1:]], 95)
        ),
        "rankingByLimit": {
            str(k): {
                metric: float(
                    np.mean([r["rankingByLimit"][str(k)][metric] for r in observations])
                )
                for metric in ["boostedRecall", "boostedScoreRecall"]
            }
            for k in [5, 10, 20, 50, 100]
        },
        "observations": observations,
    }
    os.close(fd)
    c.close()
    save(a.output / f"hnsw-hybrid-{a.scale}.json", report)
    print(
        json.dumps(
            {
                k: v
                for k, v in report.items()
                if k not in ["observations", "before", "after"]
            }
        ),
        flush=True,
    )


def mutate(a):
    n = 39066 * a.scale
    index = open_index(a)
    base = np.fromfile(a.run / "base.f32", dtype="<f4", count=1000 * D).reshape(1000, D)
    rng = np.random.default_rng(20261008)
    appended = base + rng.normal(0, 0.025 / np.sqrt(D), base.shape).astype("f4")
    appended /= np.linalg.norm(appended, axis=1, keepdims=True)
    keys = np.arange(n + 1, n + 1001, dtype=np.uint64)
    receipt = a.output / f"hnsw-mutations-{a.scale}.json"
    snapshot = a.output / "mutation.bin"
    report = {
        "engine": "usearch-hnsw",
        "dtype": a.dtype,
        "scale": a.scale,
        "windows": n,
        "batch": 1000,
        "operations": [],
        "durability": "explicit full snapshot; mutation timing alone is not durable persistence",
    }

    def change(name, callback):
        before = resources()
        start = time.perf_counter()
        callback()
        mutated = time.perf_counter() - start
        start = time.perf_counter()
        index.save(str(snapshot))
        persisted = time.perf_counter() - start
        after = resources()
        report["operations"].append(
            {
                "operation": name,
                "mutationSeconds": mutated,
                "persistSeconds": persisted,
                "totalSeconds": mutated + persisted,
                "before": before,
                "after": after,
                "snapshotBytes": snapshot.stat().st_size,
                **delta(before, after),
            }
        )
        save(receipt, report)

    def quality():
        queries = np.load(a.run / "queries.npy")
        refs = json.loads((a.run / f"truth-{a.scale}.json").read_text())
        rows = []
        index.expansion_search = 1600
        for qi, q in enumerate(queries):
            start = time.perf_counter()
            got = index.search(q, count=800, threads=1)
            ids = np.asarray(got.keys, dtype=np.int64)
            scores = 1 - np.asarray(got.distances)
            rows.append(
                {
                    "query": qi,
                    "milliseconds": (time.perf_counter() - start) * 1000,
                    "recall": len(set(rank(ids, scores)) & set(refs[qi]["plain"]))
                    / TOP,
                }
            )
        return rows

    report["beforeQuality"] = quality()
    change("append1000", lambda: index.add(keys, appended, threads=1))
    assert len(index) == n + 1000
    report["appendedProbeHits"] = int(
        sum(
            n + i + 1 in index.search(appended[i], count=800, threads=1).keys
            for i in range(0, 1000, 125)
        )
    )
    change("delete1000", lambda: index.remove(keys, threads=1))
    assert len(index) == n
    report["afterDeleteQuality"] = quality()
    index = Index.restore(str(snapshot))
    report["afterReopenQuality"] = quality()
    report["deletedAbsentAfterReopen"] = not np.any(index.contains(keys))
    assert report["deletedAbsentAfterReopen"]
    report["deletedCandidatesReturned"] = int(
        sum(
            np.count_nonzero(
                np.asarray(index.search(appended[i], count=1000, threads=1).keys) > n
            )
            for i in range(0, 1000, 125)
        )
    )
    assert report["deletedCandidatesReturned"] == 0

    def replace():
        ids = np.arange(1001, 1011, dtype=np.uint64)
        index.remove(ids, threads=1)
        index.add(ids, appended[:10], threads=1)

    change("replace10DeleteInsert", replace)
    change("deleteEntryNode", lambda: index.remove(1, threads=1))
    report["entryNodeDeletionSearchable"] = (
        len(index.search(appended[0], count=5, threads=1)) == 5
    )
    save(receipt, report)
    snapshot.unlink()
    print(
        json.dumps(
            {
                "event": "mutation",
                "dtype": a.dtype,
                "scale": a.scale,
                "operations": [
                    {k: v for k, v in x.items() if k not in ["before", "after"]}
                    for x in report["operations"]
                ],
            }
        ),
        flush=True,
    )


def main():
    p = argparse.ArgumentParser()
    p.add_argument("action", choices=["grid", "stage", "measure", "hybrid", "mutate"])
    p.add_argument("--run", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--dtype", choices=["f32", "f16", "i8"], default="f32")
    p.add_argument("--scale", type=int, default=1)
    a = p.parse_args()
    a.output.mkdir(parents=True, exist_ok=True)
    pause = a.output.parent / "pause-benchmarks"
    acknowledgement = a.output.parent / "benchmarks-paused"
    if a.action != "grid" and pause.exists():
        acknowledgement.write_text(
            json.dumps(
                {
                    "engine": "hnsw",
                    "dtype": a.dtype,
                    "scale": a.scale,
                    "action": a.action,
                }
            )
        )
        while pause.exists():
            time.sleep(0.5)
        acknowledgement.unlink(missing_ok=True)
    if a.action == "grid":
        for scale in range(1, 11):
            for action in ["stage", "measure", "hybrid", "mutate"]:
                subprocess.run(
                    [
                        sys.executable,
                        __file__,
                        action,
                        "--run",
                        str(a.run),
                        "--output",
                        str(a.output),
                        "--dtype",
                        a.dtype,
                        "--scale",
                        str(scale),
                    ],
                    check=True,
                )
    else:
        globals()[a.action](a)


if __name__ == "__main__":
    main()
