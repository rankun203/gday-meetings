"""Measure pinned text encoders on an explicitly supplied private corpus."""

import argparse
import hashlib
import importlib.metadata
import json
import platform
import resource
import subprocess
import threading
import time
from pathlib import Path

import numpy as np
import psutil
import torch
from encode import read_jsonl, synchronize
from huggingface_hub import snapshot_download
from transformers import AutoModel, AutoTokenizer

# Select models and instructions before inspecting their retrieval results.
MODELS = {
    "granite-97m": ("ibm-granite/granite-embedding-97m-multilingual-r2", "835ad14087e140460703cf0fae09f97d469d65c2", "cls"),
    "granite-311m": ("ibm-granite/granite-embedding-311m-multilingual-r2", "44399559930365213510b1ee2eb15ded83374f0e", "cls"),
    "harrier-270m": ("microsoft/harrier-oss-v1-270m", "31de22b673913c7d658c0f03f792d77c2dcf8ebd", "last"),
    "harrier-600m": ("microsoft/harrier-oss-v1-0.6b", "f9b9dc8d367d443f2479d27aa5d8d2850c0774ee", "last"),
    "qwen3-600m": ("Qwen/Qwen3-Embedding-0.6B", "97b0c614be4d77ee51c0cef4e5f07c00f9eb65b3", "last"),
    "jina-text-only": ("jinaai/jina-embeddings-v5-omni-nano-retrieval", "b7287f6b6b562e25bc4a28b939d1f936484b4137", "jina"),
}
INSTRUCTION = "Instruct: Given a meeting search query, retrieve relevant transcript passages that discuss the requested topic\nQuery: "


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model", choices=MODELS)
    parser.add_argument("dataset", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--device", choices=["cpu", "mps"], default="mps")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    if any(args.output.iterdir()):
        raise ValueError("Choose an empty output directory to keep timing runs independent.")
    torch.manual_seed(42)
    torch.set_num_threads(4)
    torch.set_num_interop_threads(4)
    queries = read_jsonl(args.dataset / "queries.jsonl")
    corpus = read_jsonl(args.dataset / "corpus.jsonl")
    digest = hashlib.sha256()
    for filename in ["queries.jsonl", "corpus.jsonl"]:
        digest.update((args.dataset / filename).read_bytes())
    for row in corpus:
        digest.update(Path(row["audio_path"]).read_bytes())
    model_id, revision, pooling = MODELS[args.model]
    signature = {
        "model": model_id, "revision": revision, "pooling": pooling,
        "device": args.device, "dtype": "float32", "batch_size": 1,
        "instruction": INSTRUCTION if pooling == "last" else None,
        "inputs_sha256": digest.hexdigest(),
        "runner_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "versions": {name: importlib.metadata.version(name) for name in
                     ["torch", "transformers", "numpy", "huggingface_hub", "psutil"]},
        "platform": platform.platform(),
        "hardware": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
        "system_memory_bytes": psutil.virtual_memory().total,
    }
    (args.output / "manifest.json").write_text(json.dumps(signature, indent=2) + "\n")
    started = time.perf_counter()
    path = Path(snapshot_download(
        model_id, revision=revision,
        allow_patterns=["*.json", "*.safetensors", "*.txt", "*.model", "*.jinja", "*.py", "README.md", "LICENSE*", "NOTICE*"],
        ignore_patterns=["onnx/*", "openvino/*"],
    ))
    download_seconds = time.perf_counter() - started
    files = {str(p.relative_to(path)): {"bytes": p.stat().st_size,
             "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
             for p in path.rglob("*") if p.is_file()}
    (args.output / "model-files.json").write_text(json.dumps(files, indent=2) + "\n")
    memory = {"rss_peak_sampled_bytes": 0, "mps_allocated_peak_sampled_bytes": 0,
              "mps_driver_peak_sampled_bytes": 0}
    stop = threading.Event()
    process = psutil.Process()

    def sample():
        while not stop.is_set():
            memory["rss_peak_sampled_bytes"] = max(memory["rss_peak_sampled_bytes"], process.memory_info().rss)
            if args.device == "mps":
                memory["mps_allocated_peak_sampled_bytes"] = max(memory["mps_allocated_peak_sampled_bytes"], torch.mps.current_allocated_memory())
                memory["mps_driver_peak_sampled_bytes"] = max(memory["mps_driver_peak_sampled_bytes"], torch.mps.driver_allocated_memory())
            stop.wait(0.01)

    monitor = threading.Thread(target=sample, daemon=True)
    monitor.start()
    before = time.perf_counter()
    options = {"modality": "text"} if pooling == "jina" else {}
    model = AutoModel.from_pretrained(
        str(path), trust_remote_code=pooling == "jina", dtype=torch.float32,
        attn_implementation="sdpa", **options,
    ).eval().to(args.device)
    model.requires_grad_(False)
    tokenizer = AutoTokenizer.from_pretrained(str(path), trust_remote_code=pooling == "jina")
    synchronize(args.device)
    load_seconds = time.perf_counter() - before
    max_length = 8192 if pooling == "jina" else 32768

    def encode(text, query):
        if pooling == "jina":
            text = ("Query: " if query else "Document: ") + text
        elif pooling == "last" and query:
            text = INSTRUCTION + text
        inputs = tokenizer(text, return_tensors="pt").to(args.device)
        count = inputs["input_ids"].shape[1]
        if count > max_length:
            raise ValueError("Input exceeds model context; do not silently truncate evidence.")
        with torch.inference_mode():
            if pooling == "jina":
                value = model.embed(**inputs)
            else:
                hidden = model(**inputs, **({"use_cache": False} if pooling == "last" else {})).last_hidden_state
                value = hidden[:, 0] if pooling == "cls" else hidden[:, -1]
            value = torch.nn.functional.normalize(value.float(), dim=-1).cpu().numpy()
        if not np.isfinite(value).all() or not np.allclose(np.linalg.norm(value, axis=1), 1, atol=1e-4):
            raise ValueError("Invalid embedding.")
        return value, count

    # Synthetic warmup avoids selecting corpus passages based on retrieval outcomes.
    before = time.perf_counter()
    encode("Find the discussion about the delivery schedule.", True)
    synchronize(args.device)
    first_inference_seconds = time.perf_counter() - before
    for _ in range(3):
        encode("The team discussed the delivery schedule and the next review.", False)
    synchronize(args.device)
    tasks = [("query", q["query_id"], q["query"]) for q in queries]
    tasks += [("transcript", c["segment_id"], c["transcript_evidence"]) for c in corpus]
    before_all = time.perf_counter()
    for index, (kind, key, text) in enumerate(tasks):
        synchronize(args.device)
        before = time.perf_counter()
        value, count = encode(text, kind == "query")
        synchronize(args.device)
        seconds = time.perf_counter() - before
        np.savez(args.output / f"{kind}-{key}.npz", embedding=value, seconds=seconds, tokens=count)
        if (index + 1) % 25 == 0:
            print(json.dumps({"model": args.model, "completed": index + 1, "total": len(tasks)}), flush=True)
    elapsed = time.perf_counter() - before_all
    stop.set()
    monitor.join()
    (args.output / "complete.json").write_text(json.dumps({
        "download_or_cache_seconds": download_seconds, "load_seconds": load_seconds,
        "first_synthetic_inference_seconds": first_inference_seconds,
        "encoding_and_save_seconds": elapsed, "tasks": len(tasks),
        "loaded_parameters": sum(p.numel() for p in model.parameters()),
        "loaded_parameter_bytes": sum(p.numel() * p.element_size() for p in model.parameters()),
        "checkpoint_bytes": sum(v["bytes"] for k, v in files.items() if k.endswith(".safetensors")),
        "downloaded_files_bytes": sum(v["bytes"] for v in files.values()),
        "process_lifetime_peak_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        **memory,
        "memory_limits": "10 ms sampling during loading and inference; RSS and MPS allocations overlap on unified memory and must not be added. Process lifetime peak also includes file hashing. No energy or Core ML measurements.",
    }, indent=2) + "\n")
    print(json.dumps({"model": args.model, "complete": True, "encoding_seconds": elapsed}), flush=True)


if __name__ == "__main__":
    main()
