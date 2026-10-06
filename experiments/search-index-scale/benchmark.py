"""SQLite retrieval scale experiment. All inputs are synthetic; no app data is read."""

from __future__ import annotations

import argparse
import importlib.metadata
import json
import platform
import resource
import shutil
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import sqlite_vec
import vectorlite_py

GIB = 1024**3
BLOCK = 4096


def emit(**row):
    print(json.dumps({"time": time.time(), **row}), flush=True)


def normalized(x):
    return x / np.linalg.norm(x, axis=-1, keepdims=True)


def fixture(n, d, count):
    rng = np.random.default_rng(20261006 + d)
    centers = normalized(rng.standard_normal((1024, d), dtype=np.float32))
    topics = np.arange(count) * 17 % min(1024, max(1, n // 120))
    queries = normalized(
        centers[topics]
        + rng.standard_normal((count, d), dtype=np.float32) * (0.3 / np.sqrt(d))
    )
    return centers, queries.astype("<f4"), topics % 97


def blocks(n, d, centers):
    rng = np.random.default_rng(41 + d)
    for start in range(0, n, BLOCK):
        ids = np.arange(start, min(n, start + BLOCK))
        noise = rng.standard_normal((len(ids), d), dtype=np.float32)
        x = normalized(centers[(ids // 120) % 1024] + noise * (0.5 / np.sqrt(d)))
        yield ids, np.asarray(x, dtype="<f4")


def top(scores, ids, k=20):
    chosen = np.argpartition(scores, -min(k, len(scores)))[-k:]
    chosen = chosen[np.argsort(-scores[chosen], kind="stable")]
    return scores[chosen], ids[chosen]


def ground_truth(n, d, count, path):
    centers, queries, people = fixture(n, d, count)
    values = [[np.empty(0, dtype=np.float32) for _ in queries] for _ in range(2)]
    identifiers = [[np.empty(0, dtype=np.int64) for _ in queries] for _ in range(2)]
    started = time.perf_counter()
    for ids, x in blocks(n, d, centers):
        scores = x @ queries.T
        for mode in range(2):
            for q in range(count):
                s = scores[:, q] + (
                    0.1 * ((ids // 120) % 97 == people[q]) if mode else 0
                )
                values[mode][q], identifiers[mode][q] = top(
                    np.concatenate((values[mode][q], s)),
                    np.concatenate((identifiers[mode][q], ids)),
                )
    np.savez(path, content=np.array(identifiers[0]), boosted=np.array(identifiers[1]))
    emit(
        stage="truth_complete", n=n, dimensions=d, seconds=time.perf_counter() - started
    )


def connect(engine, path):
    db = sqlite3.connect(path)
    db.enable_load_extension(True)
    db.load_extension(
        vectorlite_py.vectorlite_path()
        if engine == "hnsw"
        else sqlite_vec.loadable_path()
    )
    db.enable_load_extension(False)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA cache_size=-32768")
    return db


def search(db, engine, vector, k, ef):
    if engine == "hnsw":
        return db.execute(
            "SELECT rowid,distance FROM v WHERE knn_search(x,knn_param(?,?,?))",
            (vector.tobytes(), k, ef),
        ).fetchall()
    return db.execute(
        "SELECT rowid,distance FROM v WHERE x MATCH ? AND k=? ORDER BY distance",
        (vector.tobytes(), k),
    ).fetchall()


def worker(a):
    folder = Path(a.output).resolve()
    folder.mkdir(parents=True, exist_ok=True)
    dbpath = folder / "index.db"
    centers, queries, people = fixture(a.n, a.dimensions, a.queries)
    truth_path = folder.parent / f"truth-{a.n}-{a.dimensions}-q{a.queries}.npz"
    if not truth_path.exists():
        ground_truth(a.n, a.dimensions, a.queries, truth_path)
    truth = np.load(truth_path)
    db = connect(a.engine, dbpath)
    if a.engine == "hnsw":
        # PyPI 0.2.0 persists the graph using the third virtual-table argument.
        snapshot = str(folder / "graph.bin").replace("'", "''")
        db.execute(
            f"CREATE VIRTUAL TABLE v USING vectorlite(x float32[{a.dimensions}] cosine,hnsw(max_elements={a.n + 1024},M=16,ef_construction=100),'{snapshot}')"
        )
        build_info = db.execute("SELECT vectorlite_info()").fetchone()[0]
    else:
        db.execute(
            f"CREATE VIRTUAL TABLE v USING vec0(x float[{a.dimensions}] distance_metric=cosine)"
        )
        build_info = sqlite_vec.__version__
    emit(
        stage="build_start",
        engine=a.engine,
        n=a.n,
        dimensions=a.dimensions,
        build_info=build_info,
    )
    started = time.perf_counter()
    insert_seconds = 0
    for ids, x in blocks(a.n, a.dimensions, centers):
        if shutil.disk_usage(folder).free < 4 * GIB:
            raise RuntimeError("Stopped to preserve 4 GiB free disk space")
        before = time.perf_counter()
        with db:
            db.executemany(
                "INSERT INTO v(rowid,x) VALUES (?,?)",
                ((int(i), row.tobytes()) for i, row in zip(ids, x)),
            )
        insert_seconds += time.perf_counter() - before
        if ids[-1] // 100000 != ids[0] // 100000 or ids[-1] == a.n - 1:
            emit(
                stage="build_progress",
                inserted=int(ids[-1]) + 1,
                n=a.n,
                dimensions=a.dimensions,
                engine=a.engine,
            )
    build_seconds = time.perf_counter() - started
    started = time.perf_counter()
    db.close()
    persist_seconds = time.perf_counter() - started
    file_bytes = sum(p.stat().st_size for p in folder.iterdir() if p.is_file())
    started = time.perf_counter()
    db = connect(a.engine, dbpath)
    first = search(db, a.engine, queries[0], 20, 200)
    reopen_first_ms = (time.perf_counter() - started) * 1000
    if len(first) != 20:
        raise RuntimeError("Reopened index did not return 20 results")
    measurements = []
    settings = (
        [(20, 64), (100, 200), (400, 800)]
        if a.engine == "hnsw"
        else [(20, 0), (100, 0), (400, 0)]
    )
    for candidates, ef in settings:
        latencies, content_recall, boosted_recall = [], [], []
        for qi, query in enumerate(queries):
            started = time.perf_counter()
            rows = search(db, a.engine, query, candidates, ef)
            ids = np.array([r[0] for r in rows], dtype=np.int64)
            similarities = 1 - np.array([r[1] for r in rows])
            _, content = top(similarities, ids)
            _, boosted = top(
                similarities + 0.1 * ((ids // 120) % 97 == people[qi]), ids
            )
            latencies.append((time.perf_counter() - started) * 1000)
            content_recall.append(len(set(content) & set(truth["content"][qi])) / 20)
            boosted_recall.append(len(set(boosted) & set(truth["boosted"][qi])) / 20)
        measurements.append(
            {
                "candidates": candidates,
                "ef": ef,
                "p50_ms": float(np.percentile(latencies, 50)),
                "p95_ms": float(np.percentile(latencies, 95)),
                "content_recall20": float(np.mean(content_recall)),
                "boosted_recall20": float(np.mean(boosted_recall)),
            }
        )
        emit(
            stage="query_complete",
            engine=a.engine,
            n=a.n,
            dimensions=a.dimensions,
            **measurements[-1],
        )
    db.close()
    result = {
        "n": a.n,
        "dimensions": a.dimensions,
        "engine": a.engine,
        "queries": a.queries,
        "build_info": build_info,
        "build_seconds": build_seconds,
        "insert_seconds": insert_seconds,
        "persist_seconds": persist_seconds,
        "reopen_first_ms": reopen_first_ms,
        "file_bytes": file_bytes,
        "peak_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        "measurements": measurements,
        "platform": platform.platform(),
        "machine": platform.machine(),
        "sqlite": sqlite3.sqlite_version,
        "packages": {
            p: importlib.metadata.version(p)
            for p in ["numpy", "sqlite-vec", "vectorlite-py"]
        },
    }
    (folder.parent / f"{a.engine}-{a.n}-{a.dimensions}.json").write_text(
        json.dumps(result, indent=2) + "\n"
    )
    emit(stage="case_complete", engine=a.engine, n=a.n, dimensions=a.dimensions)


def suite(a):
    output = Path(a.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    for n in a.scales:
        for d in (384, 768):
            for engine in ("exact", "hnsw"):
                previous = output / f"{engine}-{n}-{d}.json"
                if previous.exists():
                    if json.loads(previous.read_text())["queries"] != a.queries:
                        raise ValueError(
                            "Use a new output folder when changing the query count"
                        )
                    continue
                # Conservative disk allowance for table pages, WAL, graph, and reserve.
                estimate = int(n * (d * 4 + 256) * 1.5 + 4 * GIB)
                if shutil.disk_usage(output).free < estimate:
                    emit(
                        stage="skipped_disk",
                        engine=engine,
                        n=n,
                        dimensions=d,
                        required_free_bytes=estimate,
                        available_bytes=shutil.disk_usage(output).free,
                    )
                    continue
                folder = output / f"case-{engine}-{n}-{d}"
                command = [
                    sys.executable,
                    __file__,
                    "--worker",
                    "--engine",
                    engine,
                    "--n",
                    str(n),
                    "--dimensions",
                    str(d),
                    "--queries",
                    str(a.queries),
                    "--output",
                    str(folder),
                ]
                result = subprocess.run(command, check=False)
                emit(
                    stage="worker_exit",
                    engine=engine,
                    n=n,
                    dimensions=d,
                    exit_code=result.returncode,
                )
                # Only this benchmark's generated case folder is removed.
                if result.returncode == 0:
                    shutil.rmtree(folder)
                else:
                    emit(
                        stage="suite_stopped",
                        reason="Inspect failed case before continuing",
                    )
                    return 1
    emit(stage="suite_complete")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--worker", action="store_true")
    parser.add_argument("--engine", choices=["exact", "hnsw"])
    parser.add_argument("--n", type=int, default=120000)
    parser.add_argument("--dimensions", type=int, default=384)
    parser.add_argument("--queries", type=int, default=40)
    parser.add_argument(
        "--scales", type=int, nargs="+", default=[120000, 1200000, 3600000]
    )
    parser.add_argument(
        "--output", default=str(Path(__file__).parent / "runs" / "scale")
    )
    args = parser.parse_args()
    if args.worker:
        worker(args)
    else:
        raise SystemExit(suite(args))
