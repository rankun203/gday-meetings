"""Synthetic lifecycle checks for the pinned HNSW precision variants."""

import json
import tempfile
from pathlib import Path

import numpy as np
from usearch.index import Index

results = {}
rng = np.random.default_rng(17)
vectors = rng.normal(size=(80, 384)).astype("f4")
vectors /= np.linalg.norm(vectors, axis=1, keepdims=True)
keys = np.arange(1, 81, dtype=np.uint64)
for dtype in ["f32", "f16", "i8"]:
    with tempfile.TemporaryDirectory() as folder:
        path = Path(folder) / "graph.bin"
        index = Index(
            ndim=384,
            metric="cos",
            dtype=dtype,
            connectivity=32,
            expansion_add=128,
            expansion_search=128,
        )
        index.add(keys, vectors, threads=1)
        assert index.search(vectors[0], count=5, threads=1).keys[0] == 1
        index.save(str(path))
        reopened = Index.restore(str(path))
        assert reopened is not None and len(reopened) == 80
        assert reopened.search(vectors[0], count=5, threads=1).keys[0] == 1
        reopened.remove(1, threads=1)
        assert 1 not in reopened.search(vectors[0], count=80, threads=1).keys
        reopened.save(str(path))
        reopened = Index.restore(str(path))
        assert not reopened.contains(1)
        reopened.add(1, vectors[0], threads=1)
        assert reopened.search(vectors[0], count=5, threads=1).keys[0] == 1
        reopened.remove([2, 3], threads=1)
        assert not np.any(reopened.contains([2, 3]))
        assert len(reopened) == 78
        results[dtype] = {
            "reopen": "passed",
            "deletedAbsentAfterReopen": "passed",
            "deleteInsert": "passed",
            "batchDelete": "passed",
            "hardware": index.hardware_acceleration,
            "snapshotBytes": path.stat().st_size,
        }
print(json.dumps(results, indent=2))
