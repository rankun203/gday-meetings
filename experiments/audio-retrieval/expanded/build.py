"""Build a private expanded gallery from fixed manifests and prewritten queries."""

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path


def rows(path):
    return [json.loads(s) for s in path.read_text().splitlines() if s.strip()]


def dump(path, data):
    path.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in data))


def project(segments, start, end):
    units = []
    for segment in segments:
        words = segment.get("words", [])
        if words and all("start" in w and "end" in w for w in words):
            units.extend(words)
        else:
            units.append(segment)
    text = " ".join(
        u.get("text", u.get("word", ""))
        for u in units
        if start <= (u["start"] + u["end"]) / 2 < end
    )
    return re.sub(
        r"(?<=[\u3400-\u9fff])\s+(?=[\u3400-\u9fff])", "", re.sub(r"\s+", " ", text)
    ).strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("config", type=Path)
    ap.add_argument("output", type=Path)
    a = ap.parse_args()
    config = json.loads(a.config.read_text())
    a.output.mkdir(parents=True, exist_ok=False)
    audio_dir = a.output / "audio"
    audio_dir.mkdir()
    base = Path(config["base"])
    manifest = json.loads((base / "private-manifest.json").read_text())
    original = rows(base / "corpus.jsonl")
    queries = rows(base / "queries.jsonl")
    additions = rows(Path(config["additional_queries"]))
    mandatory = {r["segment_id"] for r in original} | {
        p["window_id"]
        for q in additions
        for p in q["positives"]
        if p["window_id"].startswith("S")
    }
    mandatory.update(config.get("mandatory_competitors", []))
    available = [
        (sid, w)
        for sid, s in manifest.items()
        for w in s["windows"]
        if 0.35 <= w["end_s"] - w["start_s"] <= 30 and w["transcript_evidence"].strip()
    ]
    chosen = [(sid, w) for sid, w in available if w["window_id"] in mandatory]
    rest = sorted(
        [(sid, w) for sid, w in available if w["window_id"] not in mandatory],
        key=lambda pair: hashlib.sha256(
            ("expanded-v1:" + pair[1]["window_id"]).encode()
        ).hexdigest(),
    )
    chosen += rest[: config["base_windows"] - len(chosen)]
    chosen.sort(key=lambda pair: pair[1]["window_id"])
    old_by_id = {r["segment_id"]: r for r in original}
    corpus, variants, provenance = [], {}, []

    def render(ident, sources, start, end):
        dest = audio_dir / (ident + ".wav")
        duration = end - start
        cmd = ["ffmpeg", "-v", "error", "-nostdin"]
        for source in sources:
            cmd += ["-ss", str(start), "-t", str(duration), "-i", str(source)]
        filters = [
            f"[{i}:a]aresample=16000,aformat=channel_layouts=mono,apad,atrim=duration={duration}[a{i}]"
            for i in range(len(sources))
        ]
        filters.append(
            "".join(f"[a{i}]" for i in range(len(sources)))
            + f"amix=inputs={len(sources)}:duration=longest:normalize=1[out]"
        )
        subprocess.run(
            cmd
            + [
                "-filter_complex",
                ";".join(filters),
                "-map",
                "[out]",
                "-ar",
                "16000",
                "-ac",
                "1",
                "-c:a",
                "pcm_s16le",
                str(dest),
            ],
            check=True,
        )
        return str(dest.resolve())

    for i, (sid, window) in enumerate(chosen):
        ident = window["window_id"]
        start, end = window["start_s"], window["end_s"]
        if ident in old_by_id:
            row = dict(old_by_id[ident])
        else:
            row = {
                "segment_id": ident,
                "scenario_id": sid,
                "source_start_s": start,
                "source_end_s": end,
                "duration_s": end - start,
                "sample_rate": 16000,
                "channels": 1,
                "transcript_evidence": window["transcript_evidence"],
                "audio_path": render(ident, manifest[sid]["audio_paths"], start, end),
            }
        row["input_provenance"] = "historical_imported"
        corpus.append(row)
        variants[ident] = {"imported": row["transcript_evidence"]}
        if i % 100 == 0:
            print("base", i + 1, len(chosen), flush=True)
    source_to_scenario = {s["meeting_directory"]: sid for sid, s in manifest.items()}
    for spec in config["excerpts"]:
        root = Path(spec["run"])
        row = next(
            r for r in rows(root / "audio/recordings.jsonl") if r["id"] == spec["id"]
        )
        sid = source_to_scenario.get(spec["meeting_directory"], spec["meeting"])
        manifest.setdefault(
            sid,
            {
                "language": row["language"],
                "meeting_directory": spec["meeting_directory"],
            },
        )
        apple = json.loads((root / "apple" / (row["id"] + ".json")).read_text())
        imported = rows(Path(spec["meeting_directory"]) / "transcript.jsonl")
        for index, start in enumerate(range(0, int(row["duration"]), 20)):
            end = min(start + 20, row["duration"])
            ident = spec["id"] + f"-w{index + 1:02}"
            absolute_start, absolute_end = (
                start + row["source_start"],
                end + row["source_start"],
            )
            text = project(apple["segments"], start, end)
            corpus.append(
                {
                    "segment_id": ident,
                    "scenario_id": sid,
                    "audio_path": render(ident, [row["audio"]], start, end),
                    "source_start_s": absolute_start,
                    "source_end_s": absolute_end,
                    "duration_s": end - start,
                    "sample_rate": 16000,
                    "channels": 1,
                    "transcript_evidence": text,
                    "input_provenance": "fresh_apple",
                    "recording_id": row["id"],
                }
            )
            variants[ident] = {
                "imported": project(imported, absolute_start, absolute_end),
                "apple": text,
            }
            provenance.append(
                {
                    "segment_id": ident,
                    "run": str(root),
                    "recording_id": row["id"],
                    "relative_start": start,
                    "relative_end": end,
                }
            )
    queries += additions
    ids = {r["segment_id"] for r in corpus}
    assert len(ids) == len(corpus)
    for q in queries:
        assert all(p["window_id"] in ids for p in q["positives"]), q["query_id"]
        q.setdefault("cohort", "original")
    dump(a.output / "corpus.jsonl", corpus)
    dump(a.output / "queries.jsonl", queries)
    dump(a.output / "new-window-provenance.jsonl", provenance)
    (a.output / "private-manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2)
    )
    (a.output / "transcript-variants.private.json").write_text(
        json.dumps(variants, ensure_ascii=False)
    )
    (a.output / "build-config.private.json").write_bytes(a.config.read_bytes())
    (a.output / "build-summary.json").write_text(
        json.dumps(
            {
                "queries": len(queries),
                "windows": len(corpus),
                "base_windows": len(chosen),
                "new_windows": len(provenance),
                "runner_sha256": hashlib.sha256(
                    Path(__file__).read_bytes()
                ).hexdigest(),
            },
            indent=2,
        )
    )
    print("complete", len(queries), len(corpus), flush=True)


if __name__ == "__main__":
    main()
