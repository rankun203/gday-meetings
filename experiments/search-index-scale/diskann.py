"""Pinned sqlite-vec DiskANN scale experiment; private inputs/outputs stay ignored."""

import argparse
import ctypes
import json
import os
import resource
import shutil
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import psutil

D = 384
TOP = 5


def resources():
    # Darwin rusage_info_v2, from SDK sys/resource.h. Disk I/O is physical I/O,
    # not SQLite logical reads; filesystem cache hits may report zero bytes.
    values = (ctypes.c_uint64 * 20)()
    lib = ctypes.CDLL("/usr/lib/libproc.dylib")
    rc = lib.proc_pid_rusage(os.getpid(), 2, ctypes.byref(values))
    if rc:
        raise OSError("proc_pid_rusage failed")
    return {
        "rss": psutil.Process().memory_info().rss,
        "peakRSS": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        "physicalFootprint": int(values[9]),
        "readBytes": int(values[18]),
        "writtenBytes": int(values[19]),
        "cpuSeconds": time.process_time(),
    }


def connect(path, extension, readonly=False):
    c = sqlite3.connect(f"file:{path}?mode=ro" if readonly else str(path), uri=readonly)
    c.enable_load_extension(True)
    c.load_extension(str(extension))
    c.enable_load_extension(False)
    c.execute("pragma cache_size=-2048")
    c.execute("pragma mmap_size=0")
    if not readonly:
        c.execute("pragma journal_mode=wal")
    return c


def save(path, value):
    Path(path).write_text(json.dumps(value, indent=2))


def prepare(args):
    out = args.output
    out.mkdir(parents=True, exist_ok=True)
    c = sqlite3.connect(f"file:{args.library}?mode=ro", uri=True)
    spaces = c.execute(
        "select space,count(*),sum(length(vectors)) from provider_semantic_meetings where dimensions=384 group by space"
    ).fetchall()
    if len(spaces) != 1:
        raise ValueError("Expected one 384-dimensional model space")
    with (out / "base.f32").open("wb") as f:
        for (blob,) in c.execute(
            "select vectors from provider_semantic_meetings where space=? order by meeting",
            (spaces[0][0],),
        ):
            f.write(blob)
    c.close()
    base = np.fromfile(out / "base.f32", dtype="<f4").reshape(-1, D)
    assert len(base) == 39066, len(base)
    assert np.isfinite(base).all()
    # Text queries supplied separately if available; perturbed corpus queries are
    # a reproducible retrieval stress fixture, not a semantic relevance judgment.
    rng = np.random.default_rng(20261006)
    queries = base[rng.choice(len(base), 32, replace=False)].copy()
    queries += rng.normal(0, 0.06 / np.sqrt(D), queries.shape).astype("f4")
    queries /= np.linalg.norm(queries, axis=1, keepdims=True)
    np.save(out / "queries.npy", queries)
    save(
        out / "fixture.json",
        {
            "baseWindows": len(base),
            "dimensions": D,
            "seed": 20261006,
            "queryCount": len(queries),
            "perturbation": 0.06,
        },
    )


def rank(ids, scores, top=TOP):
    return ids[np.lexsort((ids, -scores))[:top]].tolist()


def score_recall(values, reference, top=TOP):
    remaining = list(reference)
    hits = 0
    for value in sorted(values, reverse=True)[:top]:
        if not remaining:
            break
        nearest = min(range(len(remaining)), key=lambda i: abs(remaining[i] - value))
        if abs(remaining[nearest] - value) <= 1e-6:
            hits += 1
            remaining.pop(nearest)
    return hits / top


def measure(args):
    out = args.output
    queries = np.load(out / "queries.npy")
    baseline = resources()
    start = time.perf_counter()
    c = connect(
        out / ("exact.db" if args.engine == "exact" else "index.db"),
        args.extension,
        readonly=True,
    )
    c.execute("select count(*) from v_info").fetchone()
    opened = resources()
    open_ms = (time.perf_counter() - start) * 1000
    result = {
        "scale": args.scale,
        "engine": args.engine,
        "windows": 39066 * args.scale,
        "baseline": baseline,
        "afterOpen": opened,
        "openMs": open_ms,
        "cases": [],
    }
    # Query settings are connection-local extension commands; permit writes on
    # benchmark DB for configuration, while input app DB remains read-only.
    c.close()
    c = connect(
        out / ("exact.db" if args.engine == "exact" else "index.db"), args.extension
    )
    labels = (
        json.loads((out / "query-labels.json").read_text())
        if (out / "query-labels.json").exists()
        else ["perturbed-corpus"] * len(queries)
    )
    references = json.loads((out / f"truth-{args.scale}.json").read_text())
    references100 = json.loads((out / f"truth100-{args.scale}.json").read_text())
    labels = labels * args.repeats
    for candidates in (
        [10, 20, 50, 100] if args.engine == "exact" else [10, 20, 50, 100, 200, 800, 1000]
    ):
        if args.engine != "exact":
            c.execute(
                f"insert into v(v) values ('search_list_size_search={max(128, candidates * 2)}')"
            )
        times, recalls, boosts, filtered = [], [], [], []
        score_recalls, score_boosts, score_filtered = [], [], []
        distance_errors = []
        observations = []
        before = resources()
        for iteration in range(len(queries) * args.repeats):
            qi = iteration % len(queries)
            q = queries[qi]
            query_before = resources()
            t = time.perf_counter()
            rows = c.execute(
                "select rowid,distance,x from v where x match ? and k=? order by distance",
                (q.tobytes(), candidates),
            ).fetchall()
            ids = np.array([r[0] for r in rows], dtype=np.int64)
            reported_scores = 1 - np.array([r[1] for r in rows])
            vectors = np.stack([np.frombuffer(r[2], dtype="<f4") for r in rows])
            scores = (vectors @ q) / (
                np.linalg.norm(vectors, axis=1) * np.linalg.norm(q)
            )
            distance_errors.append(float(np.max(np.abs(scores - reported_scores))))
            content_rank = rank(ids, scores, top=100)
            boosted_rank = rank(
                ids, scores + 0.1 * ((ids // 107) % 97 == qi % 97), top=100
            )
            allowed = ids % 5 == 0
            filtered_rank = rank(ids[allowed], scores[allowed], top=100)
            got, boosted, got_filtered = [
                r[:TOP] for r in [content_rank, boosted_rank, filtered_rank]
            ]
            times.append((time.perf_counter() - t) * 1000)
            query_after = resources()
            observations.append(
                {
                    "query": qi,
                    "repeat": iteration // len(queries),
                    "label": labels[iteration],
                    "milliseconds": times[-1],
                    "rss": query_after["rss"],
                    "peakRSS": query_after["peakRSS"],
                    "physicalFootprint": query_after["physicalFootprint"],
                    "rankingByLimit": {
                        str(limit): {
                            key: len(
                                set(got_rank[:limit])
                                & set(references100[qi][reference][:limit])
                            )
                            / limit
                            for key, got_rank, reference in zip(
                                ["contentRecall", "boostedRecall", "filteredRecall"],
                                [content_rank, boosted_rank, filtered_rank],
                                ["plain", "boost", "filtered"],
                            )
                        }
                        for limit in [10, 20, 50, 100]
                        if candidates >= limit
                    },
                    **{
                        key: query_after[key] - query_before[key]
                        for key in ["cpuSeconds", "readBytes", "writtenBytes"]
                    },
                }
            )
            truth = references[qi]
            score_recalls.append(score_recall(scores, truth["plainScores"]))
            score_boosts.append(
                score_recall(
                    scores + 0.1 * ((ids // 107) % 97 == qi % 97), truth["boostScores"]
                )
            )
            score_filtered.append(
                score_recall(scores[allowed], truth["filteredScores"])
            )
            recalls.append(len(set(got) & set(truth["plain"])) / TOP)
            boosts.append(len(set(boosted) & set(truth["boost"])) / TOP)
            filtered.append(len(set(got_filtered) & set(truth["filtered"])) / TOP)
        after = resources()
        result["cases"].append(
            {
                "candidates": candidates,
                "searchList": max(128, candidates * 2),
                "firstMs": times[0],
                "p50Ms": float(np.median(times[1:])),
                "p95Ms": float(np.percentile(times[1:], 95)),
                "timesMs": times,
                "observations": observations,
                "repeats": args.repeats,
                "rankingByLimit": {
                    limit: {
                        key: float(
                            np.mean(
                                [
                                    row["rankingByLimit"][limit][key]
                                    for row in observations
                                ]
                            )
                        )
                        for key in ["contentRecall", "boostedRecall", "filteredRecall"]
                    }
                    for limit in observations[0]["rankingByLimit"]
                },
                "byLength": {
                    label: {
                        "p50Ms": float(
                            np.median([t for t, l in zip(times, labels) if l == label])
                        ),
                        "p95Ms": float(
                            np.percentile(
                                [t for t, l in zip(times, labels) if l == label], 95
                            )
                        ),
                        "samples": labels.count(label),
                        "contentRecall": float(
                            np.mean([r for r, l in zip(recalls, labels) if l == label])
                        ),
                        "boostedRecall": float(
                            np.mean([r for r, l in zip(boosts, labels) if l == label])
                        ),
                        "filteredRecall": float(
                            np.mean([r for r, l in zip(filtered, labels) if l == label])
                        ),
                    }
                    for label in dict.fromkeys(labels)
                },
                "contentRecall": float(np.mean(recalls)),
                "contentScoreRecall": float(np.mean(score_recalls)),
                "maximumReturnedScoreError": max(distance_errors),
                "scoring": "full-fp32-candidate-rerank",
                "boostedScoreRecall": float(np.mean(score_boosts)),
                "filteredScoreRecall": float(np.mean(score_filtered)),
                "boostedRecall": float(np.mean(boosts)),
                "filteredRecall": float(np.mean(filtered)),
                "before": before,
                "after": after,
                "readBytes": after["readBytes"] - before["readBytes"],
                "cpuSeconds": after["cpuSeconds"] - before["cpuSeconds"],
            }
        )
    c.close()
    result["final"] = resources()
    save(out / f"{args.engine}-search-{args.scale}.json", result)
    print(
        json.dumps(
            {
                "event": "search",
                "engine": args.engine,
                "scale": args.scale,
                "cases": [
                    {
                        k: v
                        for k, v in r.items()
                        if k
                        in [
                            "candidates",
                            "p50Ms",
                            "contentRecall",
                            "boostedRecall",
                            "filteredRecall",
                        ]
                    }
                    for r in result["cases"]
                ],
            }
        ),
        flush=True,
    )


def truth(out, scale, top=TOP):
    queries = np.load(out / "queries.npy")
    best = [[([], []) for _ in range(3)] for _ in queries]
    # Stream reference calculations in 1024-vector chunks, not a resident corpus.
    t = time.perf_counter()
    with (out / "all.f32").open("rb") as f:
        offset = 0
        while offset < 39066 * scale:
            data = f.read(min(1024, 39066 * scale - offset) * D * 4)
            if not data:
                break
            a = np.frombuffer(data, dtype="<f4").reshape(-1, D)
            a = a / np.linalg.norm(a, axis=1, keepdims=True)
            scores = a @ queries.T
            ids = np.arange(offset + 1, offset + len(a) + 1, dtype=np.int64)
            for qi in range(len(queries)):
                for mode in range(3):
                    eligible = (
                        ids % 5 == 0 if mode == 2 else np.ones(len(ids), dtype=bool)
                    )
                    values = scores[:, qi] + (
                        0.1 * ((ids // 107) % 97 == qi % 97) if mode == 1 else 0
                    )
                    prev_i, prev_s = best[qi][mode]
                    i = np.concatenate(
                        [np.array(prev_i, dtype=np.int64), ids[eligible]]
                    )
                    s = np.concatenate([prev_s, values[eligible]])
                    order = np.lexsort((i, -s))[:top]
                    best[qi][mode] = (i[order].tolist(), s[order].tolist())
            offset += len(a)
    save(
        out / (f"truth-{scale}.json" if top == TOP else f"truth{top}-{scale}.json"),
        [
            {
                **dict(zip(["plain", "boost", "filtered"], [v[0] for v in b])),
                **dict(
                    zip(
                        ["plainScores", "boostScores", "filteredScores"],
                        [v[1] for v in b],
                    )
                ),
            }
            for b in best
        ],
    )
    return time.perf_counter() - t


def build(args):
    out = args.output
    base = np.fromfile(out / "base.f32", dtype="<f4").reshape(-1, D)
    c = connect(out / "index.db", args.extension)
    c.execute(
        f"create virtual table v using vec0(x float[{D}] distance_metric=cosine indexed by diskann(neighbor_quantizer={args.quantizer},n_neighbors={args.neighbors},search_list_size_insert={args.insert_list},search_list_size_search=128))"
    )
    c.commit()
    exact = connect(out / "exact.db", args.extension)
    exact.execute(
        f"create virtual table v using vec0(x float[{D}] distance_metric=cosine)"
    )
    exact.commit()
    cumulative = 0
    rng = np.random.default_rng(20261007)
    for scale in range(1, args.scales + 1):
        block = base.copy()
        if scale > 1:
            block += rng.normal(0, 0.04 / np.sqrt(D), block.shape).astype("f4")
        block /= np.linalg.norm(block, axis=1, keepdims=True)
        before = resources()
        start = time.perf_counter()
        paused = 0.0
        for lo in range(0, len(block), 256):
            pause_start = time.perf_counter()
            while (out / "pause").exists():
                time.sleep(0.25)
            paused += time.perf_counter() - pause_start
            if shutil.disk_usage(out).free < 4 * 1024**3:
                raise RuntimeError("4 GiB free-space reserve reached")
            c.executemany(
                "insert into v(rowid,x) values (?,?)",
                (
                    (i + 1 + (scale - 1) * len(base), v.tobytes())
                    for i, v in enumerate(block[lo : lo + 256], lo)
                ),
            )
            c.commit()
            if lo % 4096 == 0:
                print(
                    json.dumps(
                        {
                            "event": "insert",
                            "scale": scale,
                            "done": lo,
                            "seconds": time.perf_counter() - start,
                        }
                    ),
                    flush=True,
                )
        c.execute("pragma wal_checkpoint(truncate)").fetchone()
        elapsed = time.perf_counter() - start - paused
        cumulative += elapsed
        with (out / "all.f32").open("ab") as f:
            f.write(block.tobytes())
        after = resources()
        save(
            out / f"build-{scale}.json",
            {
                "scale": scale,
                "windows": scale * len(base),
                "seconds": elapsed,
                "pauseSeconds": paused,
                "neighbors": args.neighbors,
                "insertList": args.insert_list,
                "quantizer": args.quantizer,
                "cumulativeSeconds": cumulative,
                "dbBytes": (out / "index.db").stat().st_size,
                "before": before,
                "after": after,
            },
        )
        exact_before = resources()
        exact_start = time.perf_counter()
        exact.executemany(
            "insert into v(rowid,x) values (?,?)",
            (
                (i + 1 + (scale - 1) * len(base), v.tobytes())
                for i, v in enumerate(block)
            ),
        )
        exact.commit()
        exact.execute("pragma wal_checkpoint(truncate)").fetchone()
        save(
            out / f"exact-build-{scale}.json",
            {
                "seconds": time.perf_counter() - exact_start,
                "dbBytes": (out / "exact.db").stat().st_size,
                "before": exact_before,
                "after": resources(),
            },
        )
        while (out / "pause").exists() or (out / "await-queries").exists():
            time.sleep(0.25)
        truth(out, scale)
        truth(out, scale, top=100)
        # Each search worker starts without build allocations or corpus buffers.
        for engine in ["diskann", "exact"]:
            subprocess.run(
                [
                    sys.executable,
                    __file__,
                    "measure",
                    "--engine",
                    engine,
                    "--output",
                    str(out),
                    "--extension",
                    str(args.extension),
                    "--scale",
                    str(scale),
                ],
                check=True,
            )
        if args.hybrid:
            subprocess.run(
                [
                    sys.executable,
                    str(Path(__file__).with_name("hybrid_speakers.py")),
                    "--output",
                    str(out),
                    "--extension",
                    str(args.extension),
                    "--scale",
                    str(scale),
                ],
                check=True,
            )
        if args.mutations:
            subprocess.run(
                [
                    sys.executable,
                    str(Path(__file__).with_name("mutations.py")),
                    "--run",
                    str(out),
                    "--output",
                    str(out / f"mutations-{scale}"),
                    "--extension",
                    str(args.extension),
                    "--scale",
                    str(scale),
                ],
                check=True,
            )
    c.close()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("action", choices=["prepare", "build", "measure"])
    p.add_argument("--output", type=Path, required=True)
    p.add_argument(
        "--extension", type=Path, default=Path("tmp/diskann-benchmark/vec0.dylib")
    )
    p.add_argument("--library", type=Path)
    p.add_argument("--scale", type=int, default=1)
    p.add_argument("--scales", type=int, default=10)
    p.add_argument("--engine", choices=["diskann", "exact"], default="diskann")
    p.add_argument("--hybrid", action="store_true")
    p.add_argument("--mutations", action="store_true")
    p.add_argument("--repeats", type=int, default=3)
    p.add_argument("--neighbors", type=int, default=32)
    p.add_argument("--insert-list", type=int, default=64)
    p.add_argument("--quantizer", choices=["binary", "int8"], default="int8")
    args = p.parse_args()
    globals()[args.action](args)


if __name__ == "__main__":
    main()
