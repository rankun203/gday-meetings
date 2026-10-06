"""Prepare fixed-window transcript variants and score paired synthetic retrieval."""

import argparse
import hashlib
import json
import re
import sys
import unicodedata
import wave
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from compare import bm25, evidence_metrics, order_scores


def rows(path):
    return [json.loads(x) for x in Path(path).read_text().splitlines()]


def dump(path, items):
    path.write_text("".join(json.dumps(x, ensure_ascii=False) + "\n" for x in items))


def tokens(text):
    return re.findall(
        r"[\u3400-\u9fff]|[a-z0-9]+", unicodedata.normalize("NFKC", text).lower()
    )


def distance(a, b):
    previous = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        current = [i]
        for j, y in enumerate(b, 1):
            current.append(
                min(current[-1] + 1, previous[j] + 1, previous[j - 1] + (x != y))
            )
        previous = current
    return previous[-1]


def project(segments, start, end):
    units = []
    fallback = 0
    for segment in segments:
        words = segment.get("words", [])
        timed = [w for w in words if "start" in w and "end" in w]
        # Missing word timestamps are retained as an explicit fallback, never silently discarded.
        if timed and len(timed) == len(words):
            units.extend(timed)
        else:
            units.append(segment)
            fallback += 1
    selected = [
        u.get("text", u.get("word", ""))
        for u in units
        if start <= (u["start"] + u["end"]) / 2 < end
    ]
    text = re.sub(r"\s+", " ", " ".join(selected)).strip()
    text = re.sub(r"(?<=[\u3400-\u9fff])\s+(?=[\u3400-\u9fff])", "", text)
    return text, fallback


def normalize_worker_chinese(segments, converter):
    """Match the worker's segment and word conversion before time projection."""
    for segment in segments:
        segment["text"] = converter.convert(segment["text"])
        for word in segment.get("words", []):
            if "word" in word:
                word["word"] = converter.convert(word["word"])


def prepare(a):
    # Match the worker's zh-cn post-processing, before word-time projection.
    from opencc import OpenCC

    simplified = OpenCC("tw2sp")
    windows = rows(a.dataset / "windows.jsonl")
    recordings = {r["recording_id"]: r for r in rows(a.dataset / "recordings.jsonl")}
    queries = rows(a.dataset / "queries.jsonl")
    a.output.mkdir(parents=True, exist_ok=True)
    quality = []
    for source, folder in [
        ("reference", None),
        ("audio", None),
        ("apple", a.apple),
        ("whisperx", a.whisper),
    ]:
        if source not in ["reference", "audio"] and folder is None:
            continue
        for condition in ["clean", "noise10db"]:
            if source == "reference" and condition != "clean":
                continue
            root = a.output / f"{source}-{condition}"
            root.mkdir(exist_ok=True)
            corpus = []
            for w in windows:
                if w["condition"] != condition:
                    continue
                r = recordings[w["recording_id"]]
                text = w["reference"]
                fallback = 0
                if folder:
                    path = folder / (w["recording_id"] + ".json")
                    if not path.exists():
                        raise ValueError(f"Missing completed recording: {path.name}")
                    receipt = json.loads(path.read_text())
                    if receipt["audio_sha256"] != r["audio_sha256"]:
                        raise ValueError("Audio fingerprint mismatch")
                    if source == "whisperx" and r["language"] == "zh":
                        normalize_worker_chinese(receipt["segments"], simplified)
                    text, fallback = project(receipt["segments"], w["start"], w["end"])
                audio_path = r["audio_path"]
                if source == "audio":
                    clip = root / (w["segment_id"] + ".wav")
                    with wave.open(r["audio_path"], "rb") as f:
                        parameters = f.getparams()
                        rate = f.getframerate()
                        f.setpos(round(w["start"] * rate))
                        data = f.readframes(round((w["end"] - w["start"]) * rate))
                    with wave.open(str(clip), "wb") as f:
                        f.setparams(parameters)
                        f.writeframes(data)
                    audio_path = str(clip.resolve())
                corpus.append(
                    {
                        "segment_id": w["segment_id"],
                        "scenario_id": w["scenario_id"],
                        "language": w["language"],
                        "audio_path": audio_path,
                        "transcript_evidence": text,
                    }
                )
                quality.append(
                    {
                        "source": source,
                        "condition": condition,
                        "segment_id": w["segment_id"],
                        "language": w["language"],
                        "script_tokens": len(tokens(w["reference"])),
                        "edit_distance": distance(tokens(w["reference"]), tokens(text)),
                        "empty": not text,
                        "fallback_segments_in_recording": fallback,
                    }
                )
            dump(root / "corpus.jsonl", corpus)
            dump(root / "queries.jsonl", queries)
    (a.output / "transcript-quality.json").write_text(
        json.dumps(quality, indent=2) + "\n"
    )
    print("Prepared fixed-window datasets")


def score(a):
    result = []
    for root in sorted(a.output.iterdir()):
        if not root.is_dir() or not (root / "corpus.jsonl").exists():
            continue
        corpus = rows(root / "corpus.jsonl")
        queries = rows(root / "queries.jsonl")
        ids = [r["segment_id"] for r in corpus]
        if len(set(ids)) != len(ids):
            raise ValueError("Duplicate window identifiers")
        candidate_counts = {
            language: sum(c["language"] == language for c in corpus)
            for language in sorted({c["language"] for c in corpus})
        }
        audio = root.name.startswith("audio-")
        matrices = (
            {}
            if audio
            else {
                "bm25": bm25(
                    [q["query"] for q in queries],
                    [r["transcript_evidence"] for r in corpus],
                )
            }
        )
        for model in ["jina"] if audio else ["jina-text-only", "granite-311m"]:
            folder = root / model
            if not (folder / "complete.json").exists():
                continue
            digest = hashlib.sha256()
            for name in ["queries.jsonl", "corpus.jsonl"]:
                digest.update((root / name).read_bytes())
            for document in corpus:
                digest.update(Path(document["audio_path"]).read_bytes())
            if (
                json.loads((folder / "manifest.json").read_text())["inputs_sha256"]
                != digest.hexdigest()
            ):
                raise ValueError("Embedding inputs changed; rerun the affected encoder")
            q = np.concatenate(
                [
                    np.load(folder / f"query-{r['query_id']}.npz")["embedding"]
                    for r in queries
                ]
            )
            kind = "audio" if audio else "transcript"
            c = np.concatenate(
                [
                    np.load(folder / f"{kind}-{r['segment_id']}.npz")["embedding"]
                    for r in corpus
                ]
            )
            matrices[model] = q @ c.T
        for model, matrix in matrices.items():
            if (
                matrix.shape != (len(queries), len(corpus))
                or not np.isfinite(matrix).all()
            ):
                raise ValueError("Scores must be finite and cover the complete corpus")
            measured = []
            for qi, q in enumerate(queries):
                # Identical scripts in different spoken languages are separate ASR conditions.
                language = q["scenario_id"].split("-")[-1]
                allowed = [i for i, c in enumerate(corpus) if c["language"] == language]
                order = order_scores(
                    matrix[qi : qi + 1, allowed],
                    [ids[i] for i in allowed],
                    lexical=model == "bm25",
                )[0]
                ranking = [allowed[i] for i in order]
                positives = {ids.index(p) for p in q["positives"]}
                if not positives.issubset(allowed):
                    raise ValueError(
                        "A positive lies outside the query's candidate gallery"
                    )
                values = evidence_metrics(ranking, positives) if positives else None
                measured.append(
                    {
                        "query_id": q["query_id"],
                        "scenario_id": q["scenario_id"],
                        "language": language,
                        "query_language": q["language"],
                        "cross_language": q["cross_language"],
                        "kind": q["kind"],
                        "metrics": values,
                        "first": ids[ranking[0]] if ranking else None,
                    }
                )
            answered = [r for r in measured if r["metrics"] is not None]
            groups = {
                "all": answered,
                "cross_language": [r for r in answered if r["cross_language"]],
                "same_language": [r for r in answered if not r["cross_language"]],
                "en": [r for r in answered if r["language"] == "en"],
                "zh": [r for r in answered if r["language"] == "zh"],
            }
            result.append(
                {
                    "dataset": root.name,
                    "model": model,
                    "answerable_queries": len(answered),
                    "unanswerable_queries": len(measured) - len(answered),
                    "candidates_by_language": candidate_counts,
                    "evidence": {
                        g: {
                            k: float(np.mean([r["metrics"][k] for r in rs]))
                            for k in ["hit@1", "hit@5", "hit@10", "mrr"]
                        }
                        for g, rs in groups.items()
                    },
                    "per_query": measured,
                }
            )
    (a.output / "retrieval-metrics.json").write_text(
        json.dumps(result, indent=2) + "\n"
    )
    print(
        json.dumps(
            [
                {k: v for k, v in r.items() if k not in ["per_query", "evidence"]}
                | {"evidence": r["evidence"]["all"]}
                for r in result
            ],
            indent=2,
        )
    )


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("mode", choices=["prepare", "score"])
    ap.add_argument("dataset", type=Path)
    ap.add_argument("output", type=Path)
    ap.add_argument("--apple", type=Path)
    ap.add_argument("--whisper", type=Path)
    a = ap.parse_args()
    (prepare if a.mode == "prepare" else score)(a)


if __name__ == "__main__":
    main()
