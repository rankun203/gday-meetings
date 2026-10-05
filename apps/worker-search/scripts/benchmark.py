"""Measure a prepared local CLSP worker on explicitly supplied synthetic clips."""
import argparse
import json
import os
from pathlib import Path
import platform
import resource
import time

os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"

from gday_search.worker import CLSPWorker, MODEL_ID, MODEL_REVISION

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("fixture_directory", type=Path)
parser.add_argument("output", type=Path)
parser.add_argument("--device", choices=["cpu", "mps"], default="cpu")
args = parser.parse_args()
clips = [args.fixture_directory / name for name in ["slow.aiff", "fast.aiff", "second-voice.aiff"]]
if any(not path.is_file() for path in clips):
    parser.error("Supply slow.aiff, fast.aiff, and second-voice.aiff synthetic fixtures.")
worker = CLSPWorker(device=args.device)
started = time.perf_counter()
queries = [
    "A person speaks slowly with clear pauses between words.",
    "A person speaks quickly with a fast delivery.",
    "A low-pitched voice speaks clearly.",
]
text = worker.handle({"operation": "embed_text", "texts": queries})
audio = [worker.handle({"operation": "embed_audio", "path": str(path), "duration": 15}) for path in clips]
warm = worker.handle({"operation": "embed_text", "texts": queries})
scores = [[sum(a * b for a, b in zip(q, item["vectors"][0])) for item in audio] for q in text["vectors"]]
result = {
    "model": MODEL_ID, "revision": MODEL_REVISION, "device": args.device,
    "platform": platform.platform(), "clips": [path.name for path in clips], "queries": queries,
    "scores": scores, "rankings": [[clips[i].name for i in sorted(range(len(clips)), key=lambda i: -row[i])] for row in scores],
    "load_seconds": text["load_seconds"], "first_text_seconds": text["seconds"],
    "warm_text_seconds": warm["seconds"], "audio_seconds": [item["seconds"] for item in audio],
    "elapsed_seconds": time.perf_counter() - started,
    "max_rss_platform_units": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
    "limits": "Three synthesized clips; smoke test only, not a held-out retrieval-quality benchmark. macOS ru_maxrss is bytes.",
}
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
