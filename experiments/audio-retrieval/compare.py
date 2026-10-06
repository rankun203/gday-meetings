"""Compare retrieval runs and export a method-blinded relevance pool."""

import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import re
import time

import numpy as np
from sklearn.feature_extraction.text import TfidfVectorizer


def read_jsonl(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def tokens(text):
    pieces = re.findall(r"[a-z0-9]+|[\u3400-\u9fff]+", text.casefold())
    output = []
    for piece in pieces:
        if "\u3400" <= piece[0] <= "\u9fff":
            output.extend(piece)
            output.extend(piece[i:i + 2] for i in range(len(piece) - 1))
        else:
            output.append(piece)
    return output


def bm25(queries, documents, k1=1.2, b=0.75):
    counts = [Counter(tokens(doc)) for doc in documents]
    df = Counter(term for doc in counts for term in doc)
    lengths = np.array([sum(doc.values()) for doc in counts])
    average = max(float(lengths.mean()), 1)
    scores = np.zeros((len(queries), len(documents)))
    for i, query in enumerate(queries):
        for term in set(tokens(query)):
            frequency = np.array([doc[term] for doc in counts])
            idf = math.log(1 + (len(documents) - df[term] + 0.5) / (df[term] + 0.5))
            scores[i] += idf * frequency * (k1 + 1) / (frequency + k1 * (1 - b + b * lengths / average))
    return scores


def order_scores(scores, document_ids, lexical=False):
    # Opaque ID hashes break ties independently of input order or positive status.
    tie = np.array([hashlib.sha256(key.encode()).hexdigest() for key in document_ids])
    return [[int(i) for i in np.lexsort((tie, -row)) if not lexical or row[i] > 0] for row in scores]


def rrf(orders, count, constant=60):
    result = np.zeros((len(orders[0]), count))
    for order in orders:
        for qi, ranking in enumerate(order):
            for rank, di in enumerate(ranking, 1):
                result[qi, di] += 1 / (constant + rank)
    return result


def evidence_metrics(order, positives, cutoff=10):
    found = [index + 1 for index, di in enumerate(order) if di in positives]
    return {
        **{f"hit@{k}": float(any(rank <= k for rank in found)) for k in [1, 5, 10]},
        **{f"recall@{k}": sum(rank <= k for rank in found) / len(positives) for k in [1, 5, 10]},
        "mrr": 1 / found[0] if found else 0.0,
        "mrr@10": 1 / found[0] if found and found[0] <= cutoff else 0.0,
    }


def relevance_metrics(order, grades, depth=5, supports=None):
    if any(di not in grades for di in order[:depth]):
        raise ValueError("Every returned result through the scoring depth must be judged.")
    selected = [grades[di] for di in order[:depth]]
    selected += [0] * (depth - len(selected))  # no result is not relevant
    gains = lambda values: sum((2 ** grade - 1) / math.log2(i + 2) for i, grade in enumerate(values))
    ideal = gains(sorted(grades.values(), reverse=True)[:depth])
    result = {
        "useful@1": float(selected[0] >= 2), "direct@1": float(selected[0] == 3),
        f"precision@{depth}": sum(g >= 2 for g in selected) / depth,
        f"direct_precision@{depth}": sum(g == 3 for g in selected) / depth,
        f"pooled_ndcg@{depth}": gains(selected) / ideal if ideal else 0.0,
        f"any_useful@{depth}": float(any(g >= 2 for g in selected)),
    }
    if supports is not None:
        values = [supports[di] for di in order[:depth]] + ["none"] * (depth - len(order[:depth]))
        result.update({
            "full_support@1": float(values[0] == "full"),
            "some_support@1": float(values[0] in {"full", "partial"}),
            f"full_support_precision@{depth}": values.count("full") / depth,
            f"any_full_support@{depth}": float("full" in values),
        })
    return result


def aggregate(rows, indices):
    return {key: float(np.mean([rows[i][key] for i in indices])) for key in rows[0]} if indices else {}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dataset", type=Path)
    parser.add_argument("runs", type=Path)
    parser.add_argument("--judgments", type=Path)
    args = parser.parse_args()
    qs = read_jsonl(args.dataset / "queries.jsonl")
    cs = read_jsonl(args.dataset / "corpus.jsonl")
    qids, cids = [q["query_id"] for q in qs], [c["segment_id"] for c in cs]
    if not qs or not cs or len(set(qids)) != len(qids) or len(set(cids)) != len(cids):
        raise ValueError("Queries and documents must be nonempty and have unique IDs.")
    texts, docs = [q["query"] for q in qs], [c["transcript_evidence"] for c in cs]
    lookup = {key: i for i, key in enumerate(cids)}
    positives = [{lookup[p["window_id"]] for p in q["positives"]} for q in qs]
    if any(not positive for positive in positives):
        raise ValueError("Every query needs an original evidence label.")
    digest = hashlib.sha256()
    for name in ["queries.jsonl", "corpus.jsonl"]:
        digest.update((args.dataset / name).read_bytes())
    for row in cs:
        digest.update(Path(row["audio_path"]).read_bytes())
    scenarios = json.loads((args.dataset / "private-manifest.json").read_text())
    cross = [q["language"] != scenarios[q["scenario_id"]]["language"] for q in qs]
    scores, timings, lexical = {}, {}, set()
    for name in ["bm25", "word-tfidf", "character-tfidf"]:
        start = time.perf_counter()
        if name == "bm25":
            scores[name] = bm25(texts, docs)
        else:
            options = {"analyzer": "char", "ngram_range": (2, 4)} if name == "character-tfidf" else {
                "tokenizer": tokens, "token_pattern": None, "ngram_range": (1, 2)}
            vectorizer = TfidfVectorizer(sublinear_tf=True, **options)
            d = vectorizer.fit_transform(docs)
            scores[name] = (vectorizer.transform(texts) @ d.T).toarray()
        timings[name] = time.perf_counter() - start
        lexical.add(name)
    scores["clsp-audio"] = np.load(args.dataset / "reference-similarities.npy")
    if scores["clsp-audio"].shape != (len(qs), len(cs)):
        raise ValueError("CLSP matrix dimensions differ from the input corpus.")
    for model in ["e5", "jina", "clap"]:
        folder = args.runs / model
        if not (folder / "complete.json").exists():
            continue
        manifest = json.loads((folder / "manifest.json").read_text())
        if manifest["inputs_sha256"] != digest.hexdigest():
            raise ValueError(f"{model} was encoded from different inputs.")
        def vectors(kind, keys):
            return [np.load(folder / f"{kind}-{key}.npz")["embedding"] for key in keys]
        q = np.concatenate(vectors("query", qids))
        if model != "clap":
            scores[model + "-transcript"] = q @ np.concatenate(vectors("transcript", cids)).T
        if model != "e5":
            audio = vectors("audio", cids)
            if model == "clap":
                scores["clap-audio-max"] = np.stack([(q @ item.T).max(axis=1) for item in audio], axis=1)
                pooled = np.stack([item.mean(axis=0) for item in audio])
                pooled /= np.linalg.norm(pooled, axis=1, keepdims=True)
                scores["clap-audio-mean"] = q @ pooled.T
            else:
                scores[model + "-audio"] = q @ np.concatenate(audio).T
    if any(matrix.shape != (len(qs), len(cs)) or not np.isfinite(matrix).all() for matrix in scores.values()):
        raise ValueError("Score matrices must be finite and cover all queries and documents.")
    orders = {name: order_scores(matrix, cids, name in lexical) for name, matrix in scores.items()}
    for name, members in {
        "hybrid-e5-bm25": ["e5-transcript", "bm25"],
        "hybrid-jina-audio-bm25": ["jina-audio", "bm25"],
        "hybrid-jina-transcript-bm25": ["jina-transcript", "bm25"],
    }.items():
        if all(member in orders for member in members):
            scores[name] = rrf([orders[member] for member in members], len(cs))
            orders[name] = order_scores(scores[name], cids)
    np.savez(args.runs / "scores.npz", **scores)
    groups = {"all": list(range(len(qs))), "cross_language": [i for i, v in enumerate(cross) if v],
              "same_language": [i for i, v in enumerate(cross) if not v]}
    for language in sorted({q["language"] for q in qs}):
        groups[language] = [i for i, q in enumerate(qs) if q["language"] == language]
    per_query = {name: [evidence_metrics(order, positive) for order, positive in zip(ranking, positives)]
                 for name, ranking in orders.items()}
    result = {
        "queries": len(qs), "windows": len(cs), "group_sizes": {k: len(v) for k, v in groups.items()},
        "evidence": {name: {group: aggregate(rows, indices) for group, indices in groups.items()}
                     for name, rows in per_query.items()},
        "lexical_index_and_all_queries_seconds": timings,
        "limits": "Existing nonexhaustive evidence labels; same selected corpus; lexical zero scores return no result.",
    }
    pool, secret = [], []
    for qi, query in enumerate(qs):
        documents = set.union(positives[qi], *(set(ranks[qi][:5]) for ranks in orders.values()))
        # One repeatable random control per query; not assumed irrelevant.
        control = int(hashlib.sha256(query["query_id"].encode()).hexdigest(), 16) % len(cs)
        documents.add(control)
        for di in sorted(documents):
            token = hashlib.sha256(f"review-v1:{qids[qi]}:{cids[di]}".encode()).hexdigest()[:16]
            pool.append({"review_id": token, "query": query["query"], "passage": docs[di]})
            secret.append({"review_id": token, "query_id": qids[qi], "segment_id": cids[di]})
    pool.sort(key=lambda row: row["review_id"])
    for filename, rows in [("blind-pool.jsonl", pool), ("pool-key.jsonl", secret)]:
        (args.runs / filename).write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows))
    (args.runs / "rankings.json").write_text(json.dumps({
        name: {qids[qi]: [cids[di] for di in order] for qi, order in enumerate(ranking)}
        for name, ranking in orders.items()}, indent=2) + "\n")
    if args.judgments:
        judgments = read_jsonl(args.judgments)
        grades = [{} for _ in qs]
        supports = [{} for _ in qs]
        key = {row["review_id"]: row for row in secret}
        seen = set()
        for row in judgments:
            if row["review_id"] in seen or row["grade"] not in [0, 1, 2, 3] or not row.get("reason"):
                raise ValueError("Duplicate, invalid, or unexplained judgment.")
            seen.add(row["review_id"])
            item = key[row["review_id"]]
            grades[qids.index(item["query_id"])][lookup[item["segment_id"]]] = row["grade"]
            if row.get("support") not in {"full", "partial", "question_only", "none", "contradiction"}:
                raise ValueError("Every judgment needs an evidence-support assessment.")
            supports[qids.index(item["query_id"])][lookup[item["segment_id"]]] = row["support"]
        if seen != set(key):
            raise ValueError("Judge the complete pool before reporting pooled relevance.")
        relevance = {name: [relevance_metrics(order, grades[qi], supports=supports[qi]) for qi, order in enumerate(ranking)]
                     for name, ranking in orders.items()}
        result["relevance"] = {name: {group: aggregate(rows, indices) for group, indices in groups.items()}
                               for name, rows in relevance.items()}
        result["judged_pairs"] = len(seen)
        result["additional_useful_pairs"] = sum(g >= 2 and di not in positives[qi]
                                                for qi, row in enumerate(grades) for di, g in row.items())
        (args.runs / "per-query-relevance.json").write_text(json.dumps(relevance, indent=2) + "\n")
    (args.runs / "metrics.json").write_text(json.dumps(result, indent=2) + "\n")
    (args.runs / "per-query-evidence.json").write_text(json.dumps(per_query, indent=2) + "\n")
    print(json.dumps({"methods": list(orders), "pool_pairs": len(pool), "results": str(args.runs / "metrics.json")}))


if __name__ == "__main__":
    main()
