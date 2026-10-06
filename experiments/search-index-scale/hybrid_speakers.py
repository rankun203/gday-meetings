"""Test ANN content candidates plus exact scoring of identified-speaker windows."""

import argparse
import json
import time
from pathlib import Path

import numpy as np
from diskann import TOP, connect, rank, resources, save, score_recall

p = argparse.ArgumentParser()
p.add_argument("--output", type=Path, required=True)
p.add_argument("--extension", type=Path, required=True)
p.add_argument("--scale", type=int, required=True)
p.add_argument("--candidates", type=int, default=200)
a = p.parse_args()
out = a.output
c = connect(out / "index.db", a.extension)
c.execute("attach database ? as meta", (str(out / "speaker-metadata.db"),))
c.execute("pragma meta.cache_size=-2048")
c.execute("pragma meta.mmap_size=0")
n = 39066 * a.scale
c.execute(
    "create table if not exists meta.synthetic_speakers(id integer primary key, person integer not null)"
)
c.execute(
    "create index if not exists meta.synthetic_speakers_person on synthetic_speakers(person)"
)
c.executemany(
    "insert or replace into meta.synthetic_speakers values (?,?)",
    ((i, (i // 107) % 97) for i in range(1, n + 1)),
)
c.commit()
c.execute("pragma wal_checkpoint(truncate)").fetchone()
c.close()
c = connect(out / "index.db", a.extension)
c.execute("attach database ? as meta", (str(out / "speaker-metadata.db"),))
c.execute("pragma meta.cache_size=-2048")
c.execute("pragma meta.mmap_size=0")
c.execute(
    f"insert into v(v) values ('search_list_size_search={max(128, a.candidates * 2)}')"
)
queries = np.load(out / "queries.npy")
references = json.loads((out / f"truth100-{a.scale}.json").read_text())
labels = json.loads((out / "query-labels.json").read_text())
times = []
recalls = []
scores_recall = []
speaker_counts = []
observations = []
before = resources()
for qi, q in enumerate(queries):
    query_before = resources()
    start = time.perf_counter()
    rows = c.execute(
        "select rowid,x from v where x match ? and k=?", (q.tobytes(), a.candidates)
    ).fetchall()
    # Normal SQLite index resolves confirmed speaker associations; vector point
    # lookups use the public virtual table, not implementation shadow tables.
    speaker_rows = c.execute(
        "select v.rowid,v.x from meta.synthetic_speakers s cross join v where v.rowid=s.id and s.person=?",
        (qi % 97,),
    ).fetchall()
    vectors_by_id = {row[0]: row[1] for row in rows + speaker_rows}
    ids = np.array(list(vectors_by_id), dtype=np.int64)
    matrix = np.stack([np.frombuffer(v, dtype="<f4") for v in vectors_by_id.values()])
    scores = (matrix @ q) / (np.linalg.norm(matrix, axis=1) * np.linalg.norm(q))
    scores += 0.1 * ((ids // 107) % 97 == qi % 97)
    got = rank(ids, scores, top=100)
    times.append((time.perf_counter() - start) * 1000)
    recalls.append(len(set(got[:TOP]) & set(references[qi]["boost"][:TOP])) / TOP)
    scores_recall.append(score_recall(scores, references[qi]["boostScores"][:TOP]))
    speaker_counts.append(len(speaker_rows))
    query_after = resources()
    observations.append(
        {
            "label": labels[qi],
            "milliseconds": times[-1],
            "rss": query_after["rss"],
            "physicalFootprint": query_after["physicalFootprint"],
            **{
                key: query_after[key] - query_before[key]
                for key in ["cpuSeconds", "readBytes", "writtenBytes"]
            },
            "rankingByLimit": {
                str(k): {
                    "boostedRecall": len(
                        set(got[:k]) & set(references[qi]["boost"][:k])
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
after = resources()
c.close()
result = {
    "scale": a.scale,
    "windows": n,
    "candidates": a.candidates,
    "firstMs": times[0],
    "p50Ms": float(np.median(times[1:])),
    "p95Ms": float(np.percentile(times[1:], 95)),
    "boostedRecall": float(np.mean(recalls)),
    "boostedScoreRecall": float(np.mean(scores_recall)),
    "minSpeakerWindows": min(speaker_counts),
    "maxSpeakerWindows": max(speaker_counts),
    "before": before,
    "after": after,
    "timesMs": times,
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
save(out / f"hybrid-{a.scale}-{a.candidates}.json", result)
print(
    json.dumps(
        {
            k: v
            for k, v in result.items()
            if k not in ["before", "after", "timesMs", "observations"]
        }
    )
)
