"""Run pinned WhisperX recognition and alignment locally, retaining provenance."""

import argparse
import hashlib
import importlib.metadata
import json
import os
import platform
import time
from pathlib import Path

os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
os.environ.setdefault("OMP_NUM_THREADS", "4")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("recordings", type=Path)
    ap.add_argument("model_receipt", type=Path)
    ap.add_argument("output", type=Path)
    ap.add_argument("--limit", type=int)
    a = ap.parse_args()
    a.output.mkdir(parents=True, exist_ok=True)
    import torch
    import whisperx

    torch.set_num_threads(4)
    model_info = json.loads(a.model_receipt.read_text())
    signature = {
        "engine": "WhisperX",
        "model": model_info,
        "device": "cpu",
        "compute_type": "int8",
        "batch_size": 1,
        "platform": platform.platform(),
        "runner_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "versions": {
            x: importlib.metadata.version(x)
            for x in [
                "whisperx",
                "faster-whisper",
                "ctranslate2",
                "torch",
                "torchaudio",
                "pyannote.audio",
                "transformers",
            ]
        },
    }
    manifest = a.output / "manifest.json"
    if manifest.exists() and json.loads(manifest.read_text()) != signature:
        raise ValueError("Run signature changed")
    manifest.write_text(json.dumps(signature, indent=2) + "\n")
    before = time.perf_counter()
    model = whisperx.load_model(
        model_info["path"], "cpu", compute_type="int8", threads=4, language="en"
    )
    load_seconds = time.perf_counter() - before
    aligners = {}
    records = [json.loads(x) for x in a.recordings.read_text().splitlines()]
    if a.limit:
        records = records[: a.limit]
    for r in records:
        output = a.output / (r["recording_id"] + ".json")
        digest = hashlib.sha256(Path(r["audio_path"]).read_bytes()).hexdigest()
        if digest != r["audio_sha256"]:
            raise ValueError("Source audio changed")
        if output.exists():
            if json.loads(output.read_text())["audio_sha256"] != digest:
                raise ValueError("Cached audio mismatch")
            continue
        audio = whisperx.load_audio(r["audio_path"])
        started = time.perf_counter()
        result = model.transcribe(
            audio, batch_size=1, language=r["language"], task="transcribe"
        )
        recognition_seconds = time.perf_counter() - started
        if r["language"] not in aligners:
            aligners[r["language"]] = whisperx.load_align_model(
                language_code=r["language"],
                device="cpu",
                model_dir=str(a.output / "alignment-models"),
            )
        aligner, metadata = aligners[r["language"]]
        started = time.perf_counter()
        aligned = whisperx.align(
            result["segments"],
            aligner,
            metadata,
            audio,
            "cpu",
            return_char_alignments=False,
        )
        receipt = {
            "recording_id": r["recording_id"],
            "audio_sha256": digest,
            "language": r["language"],
            "duration_seconds": len(audio) / 16000,
            "load_seconds": load_seconds,
            "recognition_seconds": recognition_seconds,
            "alignment_seconds": time.perf_counter() - started,
            "segments": aligned["segments"],
            "raw_segments": result["segments"],
        }
        output.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
        print(
            json.dumps(
                {
                    "completed": r["recording_id"],
                    "recognition_seconds": recognition_seconds,
                }
            ),
            flush=True,
        )
    # Alignment models are auxiliary and independently fingerprinted after loading.
    hashes = {
        str(p.relative_to(a.output)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in (a.output / "alignment-models").rglob("*")
        if p.is_file()
    }
    (a.output / "alignment-files.json").write_text(json.dumps(hashes, indent=2) + "\n")


if __name__ == "__main__":
    main()
