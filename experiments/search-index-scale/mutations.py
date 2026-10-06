"""Append/delete throughput and graph recovery on disposable benchmark copies."""

import argparse
import ctypes
import json
import shutil
import sqlite3
import time
from pathlib import Path

import numpy as np
from diskann import TOP, D, connect, rank, resources, save, score_recall


def clone(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    lib = ctypes.CDLL(None, use_errno=True)
    if lib.clonefile(str(source).encode(), str(destination).encode(), 0) != 0:
        shutil.copy2(source, destination)


def measure_change(c, path, name, callback):
    before = resources()
    size = path.stat().st_size
    start = time.perf_counter()
    c.execute("begin")
    callback()
    c.commit()
    commit = time.perf_counter()
    c.execute("pragma wal_checkpoint(truncate)").fetchone()
    end = time.perf_counter()
    after = resources()
    result = {
        "operation": name,
        "transactionSeconds": commit - start,
        "checkpointSeconds": end - commit,
        "totalSeconds": end - start,
        "before": before,
        "after": after,
        "readBytes": after["readBytes"] - before["readBytes"],
        "writtenBytes": after["writtenBytes"] - before["writtenBytes"],
        "cpuSeconds": after["cpuSeconds"] - before["cpuSeconds"],
        "databaseBytes": path.stat().st_size,
        "databaseGrowthBytes": path.stat().st_size - size,
        "freePages": c.execute("pragma freelist_count").fetchone()[0],
    }
    print(
        json.dumps({k: v for k, v in result.items() if k not in ["before", "after"]}),
        flush=True,
    )
    return result


def verify(c, queries, references, candidates):
    recalls = []
    score_recalls = []
    times = []
    for q, reference in zip(queries, references):
        start = time.perf_counter()
        rows = c.execute(
            "select rowid,x from v where x match ? and k=?", (q.tobytes(), candidates)
        ).fetchall()
        ids = np.array([r[0] for r in rows], dtype=np.int64)
        matrix = np.stack([np.frombuffer(r[1], dtype="<f4") for r in rows])
        scores = (matrix @ q) / (np.linalg.norm(matrix, axis=1) * np.linalg.norm(q))
        got = rank(ids, scores)
        times.append((time.perf_counter() - start) * 1000)
        recalls.append(len(set(got) & set(reference["plain"])) / TOP)
        score_recalls.append(score_recall(scores, reference["plainScores"]))
    return {
        "recall": float(np.mean(recalls)),
        "scoreRecall": float(np.mean(score_recalls)),
        "p50Ms": float(np.median(times)),
        "timesMs": times,
    }


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--run", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--extension", type=Path, required=True)
    p.add_argument("--scale", type=int, required=True)
    p.add_argument("--engine", choices=["diskann", "exact", "both"], default="both")
    a = p.parse_args()
    a.output.mkdir(parents=True, exist_ok=True)
    n = 39066 * a.scale
    with (a.run / "base.f32").open("rb") as f:
        base = np.frombuffer(f.read(1000 * D * 4), dtype="<f4").reshape(1000, D).copy()
    rng = np.random.default_rng(20261008)
    appended = base + rng.normal(0, 0.025 / np.sqrt(D), base.shape).astype("f4")
    appended /= np.linalg.norm(appended, axis=1, keepdims=True)
    (a.output / "append.f32").write_bytes(appended.tobytes())
    selected = list(range(len(np.load(a.run / "queries.npy"))))
    queries = np.load(a.run / "queries.npy")[selected]
    refs = [
        json.loads((a.run / f"truth-{a.scale}.json").read_text())[i] for i in selected
    ]
    for engine, filename in [("diskann", "index.db"), ("exact", "exact.db")]:
        if a.engine not in ["both", engine]:
            continue
        path = a.output / f"{engine}.db"
        clone(a.run / filename, path)
        c = connect(path, a.extension)
        if engine == "diskann":
            c.execute("insert into v(v) values ('search_list_size_search=1600')")
            c.commit()
        candidates = 800 if engine == "diskann" else 5
        result = {
            "engine": engine,
            "scale": a.scale,
            "windows": n,
            "batch": 1000,
            "operations": [],
        }
        receipt = a.output / f"{engine}-mutations-{a.scale}.json"
        result["beforeQuality"] = verify(c, queries, refs, candidates)
        save(receipt, result)
        result["operations"].append(
            measure_change(
                c,
                path,
                "append1000",
                lambda c=c: c.executemany(
                    "insert into v(rowid,x) values (?,?)",
                    ((n + i + 1, v.tobytes()) for i, v in enumerate(appended)),
                ),
            )
        )
        save(receipt, result)
        assert c.execute("select count(*) from v").fetchone()[0] == n + 1000
        self_hits = 0
        for i in range(0, 1000, 125):
            rows = c.execute(
                "select rowid from v where x match ? and k=?",
                (appended[i].tobytes(), candidates),
            ).fetchall()
            self_hits += int((n + i + 1,) in rows)
        result["appendedProbeHits"] = self_hits
        result["appendedProbeCount"] = 8

        def delete_batch(c=c, engine=engine):
            start = time.perf_counter()
            for lo in range(0, 1000, 100):
                c.executemany(
                    "delete from v where rowid=?",
                    ((n + i + 1,) for i in range(lo, lo + 100)),
                )
                print(
                    json.dumps(
                        {
                            "event": "deleteProgress",
                            "engine": engine,
                            "scale": a.scale,
                            "deleted": lo + 100,
                            "seconds": time.perf_counter() - start,
                        }
                    ),
                    flush=True,
                )

        result["operations"].append(measure_change(c, path, "delete1000", delete_batch))
        save(receipt, result)
        assert c.execute("select count(*) from v").fetchone()[0] == n
        assert (
            c.execute("select count(*) from v where rowid>?", (n,)).fetchone()[0] == 0
        )
        result["afterDeleteQuality"] = verify(c, queries, refs, candidates)
        save(receipt, result)
        c.close()
        c = connect(path, a.extension)
        if engine == "diskann":
            c.execute("insert into v(v) values ('search_list_size_search=1600')")
            c.commit()
        assert (
            c.execute("select count(*) from v where rowid>?", (n,)).fetchone()[0] == 0
        )
        result["afterReopenQuality"] = verify(c, queries, refs, candidates)
        result["deletedAbsentAfterReopen"] = True
        result["deletedCandidatesReturned"] = sum(
            key > n
            for i in range(0, 1000, 125)
            for (key,) in c.execute(
                "select rowid from v where x match ? and k=?",
                (appended[i].tobytes(), candidates),
            )
        )
        assert result["deletedCandidatesReturned"] == 0
        save(receipt, result)

        def replace_ten(c=c):
            for i in range(10):
                c.execute("delete from v where rowid=?", (1001 + i,))
                c.execute(
                    "insert into v(rowid,x) values (?,?)",
                    (1001 + i, appended[i].tobytes()),
                )

        result["operations"].append(
            measure_change(c, path, "replace10DeleteInsert", replace_ten)
        )
        save(receipt, result)
        for i in range(10):
            assert (
                c.execute("select x from v where rowid=?", (1001 + i,)).fetchone()[0]
                == appended[i].tobytes()
            )
        result["replacementValuesVerified"] = True
        result["operations"].append(
            measure_change(
                c,
                path,
                "deleteEntryNode",
                lambda c=c: c.execute("delete from v where rowid=1"),
            )
        )
        save(receipt, result)
        try:
            result["deletedPointLookup"] = c.execute(
                "select count(*) from v where rowid=1"
            ).fetchone()[0]
            assert result["deletedPointLookup"] == 0
        except sqlite3.OperationalError as error:
            result["deletedPointLookupError"] = str(error)
        assert c.execute("select count(*) from v").fetchone()[0] == n - 1
        # A query after deleting the initial entry point must still traverse.
        assert c.execute(
            "select rowid from v where x match ? and k=5", (queries[0].tobytes(),)
        ).fetchall()
        result["entryNodeDeletionSearchable"] = True
        result["sqliteIntegrity"] = c.execute("pragma integrity_check").fetchone()[0]
        assert result["sqliteIntegrity"] == "ok"
        c.close()
        save(a.output / f"{engine}-mutations-{a.scale}.json", result)
        # Mutation copies are disposable. Keep compact aggregate receipts only.
        for suffix in ["", "-wal", "-shm"]:
            Path(str(path) + suffix).unlink(missing_ok=True)


if __name__ == "__main__":
    main()
