"""Synthetic lifecycle contract probes for the pinned experimental extension."""

import json
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from diskann import connect

extension = Path(sys.argv[1]).resolve()
results = {}
with tempfile.TemporaryDirectory() as folder:
    path = Path(folder) / "test.db"
    c = connect(path, extension)
    ddl = "create virtual table v using vec0(x float[8] distance_metric=cosine indexed by diskann(neighbor_quantizer=int8,n_neighbors=8))"
    c.execute(ddl)
    rng = np.random.default_rng(7)
    vectors = rng.normal(size=(80, 8)).astype("f4")
    vectors /= np.linalg.norm(vectors, axis=1, keepdims=True)
    c.executemany(
        "insert into v(rowid,x) values (?,?)",
        [(i + 1, v.tobytes()) for i, v in enumerate(vectors)],
    )
    c.commit()

    def nearest(v):
        return c.execute(
            "select rowid from v where x match ? and k=5 order by distance",
            (v.tobytes(),),
        ).fetchall()

    assert nearest(vectors[0])[0][0] == 1
    c.close()
    c = connect(path, extension)
    assert nearest(vectors[0])[0][0] == 1
    results["reopen"] = "passed"
    errors = []
    for q in vectors[:8]:
        rows = c.execute(
            "select rowid,distance,x from v where x match ? and k=20", (q.tobytes(),)
        ).fetchall()
        for _, distance, blob in rows:
            v = np.frombuffer(blob, dtype="<f4")
            expected = 1 - float(np.dot(v, q) / (np.linalg.norm(v) * np.linalg.norm(q)))
            errors.append(abs(distance - expected))
    results["maximumReturnedDistanceError"] = max(errors)
    results["distanceContract"] = (
        "passed"
        if max(errors) < 1e-6
        else "failed: requires independent FP32 reranking"
    )

    c.execute("begin")
    c.execute("delete from v where rowid=1")
    c.execute("insert into v(rowid,x) values(1,?)", (vectors[1].tobytes(),))
    c.rollback()
    assert nearest(vectors[0])[0][0] == 1
    results["replacementRollback"] = "passed"
    c.execute("delete from v where rowid=1")
    c.commit()
    assert (1,) not in nearest(vectors[0])
    results["delete"] = "passed"
    try:
        assert c.execute("select count(*) from v where rowid=1").fetchone()[0] == 0
        results["deletedPointLookup"] = "passed"
    except sqlite3.OperationalError as error:
        results["deletedPointLookup"] = "failed: " + str(error)
    c.execute("insert into v(rowid,x) values(1,?)", (vectors[0].tobytes(),))
    c.commit()
    assert nearest(vectors[0])[0][0] == 1
    results["deleteInsertReplacement"] = "passed"
    try:
        c.execute("update v set x=? where rowid=1", (vectors[1].tobytes(),))
        results["directUpdate"] = "supported"
    except sqlite3.OperationalError as e:
        results["directUpdate"] = str(e)
    for col in ["tag integer metadata", "space text partition key"]:
        try:
            c.execute(
                ddl.replace(" v ", " extra ").replace(
                    "n_neighbors=8))", f"n_neighbors=8),{col})"
                )
            )
            results[col] = "supported"
        except sqlite3.OperationalError as e:
            results[col] = str(e)
    c.rollback()
    reader = connect(path, extension)
    c.execute("insert into v(rowid,x) values(81,?)", (vectors[2].tobytes(),))
    assert reader.execute("select count(*) from v").fetchone()[0] == 80
    c.commit()
    assert reader.execute("select count(*) from v").fetchone()[0] == 81
    reader.close()
    results["concurrentReaderCommitVisibility"] = "passed"
    c.close()
    interrupted = """
import os, sqlite3, sys
c=sqlite3.connect(sys.argv[1]);c.enable_load_extension(True);c.load_extension(sys.argv[2])
c.execute('begin');c.execute('delete from v where rowid=1');os._exit(0)
"""
    subprocess.run(
        [sys.executable, "-c", interrupted, str(path), str(extension)], check=True
    )
    c = connect(path, extension)
    assert nearest(vectors[0])[0][0] == 1
    assert c.execute("select count(*) from v").fetchone()[0] == 81
    results["interruptedUncommittedDelete"] = "passed"
    c.execute("alter table v rename to renamed")
    c.commit()
    assert c.execute("select count(*) from renamed").fetchone()[0] == 81
    results["rename"] = "passed"
    assert c.execute("pragma integrity_check").fetchone()[0] == "ok"
    results["integrityCheck"] = "passed"
    c.close()
print(json.dumps(results, indent=2))
