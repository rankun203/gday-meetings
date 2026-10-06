"""Prepare transcript-input ablations without changing queries or audio windows."""

import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path

from build import dump, project, rows


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("dataset", type=Path)
    ap.add_argument("whisper", type=Path)
    ap.add_argument("patches", type=Path)
    ap.add_argument("output", type=Path)
    a = ap.parse_args()
    from opencc import OpenCC

    convert = OpenCC("tw2sp")
    corpus = rows(a.dataset / "corpus.jsonl")
    metadata = rows(a.dataset / "new-window-provenance.jsonl")
    variants = json.loads((a.dataset / "transcript-variants.private.json").read_text())
    patches = json.loads(a.patches.read_text())
    receipts = {}
    for row in metadata:
        rid = row["recording_id"]
        if rid not in receipts:
            receipts[rid] = json.loads((a.whisper / (rid + ".json")).read_text())
            source = next(
                r
                for r in rows(Path(row["run"]) / "audio/recordings.jsonl")
                if r["id"] == rid
            )
            if receipts[rid]["audio_sha256"] != source["sha256"]:
                raise ValueError("WhisperX source fingerprint mismatch")
        receipt = receipts[rid]
        if receipt["duration_seconds"] < row["relative_end"] - 0.1:
            raise ValueError("Recognition receipt does not cover the window")
        text = project(receipt["segments"], row["relative_start"], row["relative_end"])
        if receipt["language"] == "zh":
            text = convert.convert(text)
        variants[row["segment_id"]]["whisperx"] = text
    for condition in ["imported", "whisperx", "review-patched-apple"]:
        output = a.output / condition
        output.mkdir(parents=True, exist_ok=False)
        result = []
        changed = []
        for row in corpus:
            item = dict(row)
            ident = row["segment_id"]
            if ident in {x["segment_id"] for x in metadata}:
                if condition == "review-patched-apple":
                    text = row["transcript_evidence"]
                    for patch in patches.get(ident, []):
                        if text.count(patch["before"]) != 1:
                            raise ValueError("Patch must match once: " + ident)
                        text = text.replace(patch["before"], patch["after"])
                    item["transcript_evidence"] = text
                else:
                    item["transcript_evidence"] = variants[ident][condition]
                item["input_provenance"] = condition
            if item["transcript_evidence"] != row["transcript_evidence"]:
                changed.append(ident)
            result.append(item)
        dump(output / "corpus.jsonl", result)
        for name in ["queries.jsonl", "private-manifest.json"]:
            (output / name).write_bytes((a.dataset / name).read_bytes())
        (output / "variant-summary.json").write_text(
            json.dumps(
                {
                    "condition": condition,
                    "changed_windows": changed,
                    "new_windows": len(metadata),
                    "queries_unchanged": True,
                    "audio_unchanged": True,
                    "opencc_version": importlib.metadata.version("opencc"),
                    "patches_sha256": hashlib.sha256(
                        a.patches.read_bytes()
                    ).hexdigest(),
                    "recognition_receipt_hashes": {
                        key: hashlib.sha256(
                            (a.whisper / (key + ".json")).read_bytes()
                        ).hexdigest()
                        for key in receipts
                    },
                    "limits": "Review patches are local human corrections, not complete gold transcripts. Imported provenance varies; WhisperX is a fresh pinned CPU/int8 run.",
                },
                indent=2,
            )
        )
        print(condition, len(changed), "changed windows", flush=True)


if __name__ == "__main__":
    main()
