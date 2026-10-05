"""Explicit model preparation and JSON-lines embeddings for a local subprocess."""
from __future__ import annotations

import argparse
import contextlib
import json
import hashlib
import os
import sys
import time
from pathlib import Path

MODEL_ID = "yfyeung/CLSP"
MODEL_REVISION = "30355ce67960e4cc1562e4e5fa154baf86a21430"
TOKENIZER_REVISION = "e2da8e2f811d1448a5b465c236feacd80ffbac7b"
SAMPLE_RATE = 16000
MAX_SECONDS = 30
MAX_LINE_BYTES = 1024 * 1024


def prepare() -> str:
    from huggingface_hub import snapshot_download

    path = snapshot_download(
        MODEL_ID, revision=MODEL_REVISION,
        allow_patterns=["*.py", "*.json", "*.safetensors", "README.md"],
    )
    # Upstream CLSP constructs this tokenizer/config by name inside its constructor.
    tokenizer = snapshot_download("roberta-base", allow_patterns=[
        "config.json", "tokenizer.json", "tokenizer_config.json", "vocab.json", "merges.txt",
    ])
    if Path(tokenizer).name != TOKENIZER_REVISION:
        raise RuntimeError("The upstream tokenizer changed; review it before preparing this worker.")
    from huggingface_hub.constants import HF_HOME
    cache = Path(HF_HOME).resolve()
    files = []
    for directory in [Path(path), Path(tokenizer)]:
        for file in sorted(directory.iterdir()):
            if not file.is_file():
                continue
            digest = hashlib.sha256()
            with file.open("rb") as source:
                for chunk in iter(lambda: source.read(1024 * 1024), b""):
                    digest.update(chunk)
            stat = file.stat()
            files.append({"path": str(file.relative_to(cache)), "size": stat.st_size,
                          "modified": stat.st_mtime, "sha256": digest.hexdigest()})
    marker = {"version": 1, "modelID": MODEL_ID, "modelRevision": MODEL_REVISION,
              "tokenizerRevision": TOKENIZER_REVISION, "files": files}
    temporary = cache / "gday-clsp-prepared.json.tmp"
    temporary.write_text(json.dumps(marker, indent=2) + "\n")
    temporary.replace(cache / "gday-clsp-prepared.json")
    return path


class CLSPWorker:
    def __init__(self, device: str = "cpu", threads: int = 4):
        self.device = device
        self.threads = threads
        self.model = None
        self.load_seconds = None

    def load(self):
        if self.model is not None:
            return self.model
        import torch
        from transformers import AutoModel

        from huggingface_hub import snapshot_download
        tokenizer = snapshot_download("roberta-base", local_files_only=True)
        if Path(tokenizer).name != TOKENIZER_REVISION:
            raise RuntimeError("Prepare the reviewed tokenizer revision before loading the worker.")
        torch.set_num_threads(self.threads)
        started = time.perf_counter()
        # Preparation is explicit. Querying must not download code or weights.
        model = AutoModel.from_pretrained(
            MODEL_ID, revision=MODEL_REVISION, code_revision=MODEL_REVISION,
            trust_remote_code=True, local_files_only=True,
        ).eval().to(self.device)
        self.model = model
        self.load_seconds = time.perf_counter() - started
        return model

    def handle(self, request: dict) -> dict:
        operation = request.get("operation")
        if operation == "health":
            return {"ready": self.model is not None, "model": MODEL_ID, "revision": MODEL_REVISION}
        if operation not in {"embed_text", "embed_audio"}:
            raise ValueError("Choose health, embed_text, or embed_audio.")
        texts = request.get("texts")
        if operation == "embed_text":
            if not isinstance(texts, list) or not 1 <= len(texts) <= 64:
                raise ValueError("Supply between 1 and 64 search descriptions.")
            if any(not isinstance(x, str) or not x.strip() or len(x) > 4096 for x in texts):
                raise ValueError("Each description must contain 1–4096 characters.")
        import torch
        model = self.load()
        started = time.perf_counter()
        # CLSP controls gradient mode inside its encoders. Freeze both explicitly;
        # inference_mode conflicts with the upstream custom autograd functions.
        with torch.no_grad():
            if operation == "embed_text":
                _, vectors, _ = model(text=texts, freeze_audio_encoder=True, freeze_text_encoder=True)
            else:
                import soundfile as sf
                import torchaudio
                path = Path(request["path"])
                start = float(request.get("start", 0))
                duration = float(request.get("duration", 10))
                import math
                if not math.isfinite(start) or not math.isfinite(duration) or start < 0 or not 0 < duration <= MAX_SECONDS:
                    raise ValueError("Choose an audio range of up to 30 seconds.")
                with sf.SoundFile(path) as source:
                    source.seek(min(len(source), round(start * source.samplerate)))
                    samples = source.read(round(duration * source.samplerate), dtype="float32", always_2d=True)
                    rate = source.samplerate
                if len(samples) < rate / 4:
                    raise ValueError("The selected audio range is too short.")
                audio = torch.from_numpy(samples.mean(axis=1))
                if rate != SAMPLE_RATE:
                    audio = torchaudio.functional.resample(audio, rate, SAMPLE_RATE)
                if not torch.isfinite(audio).all():
                    raise ValueError("The audio contains invalid samples.")
                audio = audio.unsqueeze(0).to(self.device)
                lengths = torch.tensor([audio.shape[1]], device=self.device)
                vectors, _, _ = model(audio=audio, audio_lens=lengths, freeze_audio_encoder=True, freeze_text_encoder=True)
            vectors = vectors.float().cpu()
            if vectors.ndim != 2 or vectors.shape[1] != 512 or not torch.isfinite(vectors).all():
                raise ValueError("The model returned invalid embeddings.")
        return {
            "model": MODEL_ID, "revision": MODEL_REVISION,
            "preprocessing": "clsp-16khz-mono-v1", "dimension": 512, "normalization": "unitL2",
            "vectors": vectors.tolist(), "seconds": time.perf_counter() - started,
            "load_seconds": self.load_seconds,
        }


def serve(worker: CLSPWorker):
    # stdout is exclusively protocol data. Library progress and diagnostics go to stderr.
    while True:
        line = sys.stdin.buffer.readline(MAX_LINE_BYTES + 1)
        if not line:
            return
        identifier = None
        try:
            if len(line) > MAX_LINE_BYTES:
                raise ValueError("The request exceeds the worker's size limit.")
            request = json.loads(line)
            if not isinstance(request, dict):
                raise ValueError("The request must be an object.")
            identifier = request.get("id")
            with contextlib.redirect_stdout(sys.stderr):
                result = worker.handle(request)
            response = {"id": identifier, "final": True, "result": result}
        except Exception as error:
            response = {"id": identifier, "final": True, "error": str(error)}
        print(json.dumps(response, allow_nan=False), flush=True)
        if len(line) > MAX_LINE_BYTES:
            return


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["prepare", "serve"])
    parser.add_argument("--device", choices=["cpu", "mps"], default="cpu")
    parser.add_argument("--threads", type=int, default=4)
    args = parser.parse_args()
    if not 1 <= args.threads <= 16:
        parser.error("threads must be between 1 and 16")
    if args.command == "prepare":
        print(prepare())
    else:
        # Also constrain upstream nested tokenizer/config loading to the prepared cache.
        import os
        os.environ["HF_HUB_OFFLINE"] = "1"
        os.environ["TRANSFORMERS_OFFLINE"] = "1"
        serve(CLSPWorker(args.device, args.threads))


if __name__ == "__main__":
    main()
