"""Encode an explicitly supplied private corpus; never import it into source control."""

import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import time

import numpy as np
import soundfile as sf
import torch
from huggingface_hub import snapshot_download
from transformers import AutoModel, AutoTokenizer, ClapModel, ClapProcessor, WhisperFeatureExtractor


MODELS = {
    "clap": ("laion/clap-htsat-unfused", "8fa0f1c6d0433df6e97c127f64b2a1d6c0dcda8a"),
    "jina": ("jinaai/jina-embeddings-v5-omni-nano-retrieval", "b7287f6b6b562e25bc4a28b939d1f936484b4137"),
    "e5": ("intfloat/multilingual-e5-small", "614241f622f53c4eeff9890bdc4f31cfecc418b3"),
}


def read_jsonl(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def synchronize(device):
    if device == "mps":
        torch.mps.synchronize()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model", choices=MODELS)
    parser.add_argument("dataset", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--device", choices=["cpu", "mps"], default="cpu")
    parser.add_argument("--local-model", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    torch.manual_seed(42)
    np.random.seed(42)
    torch.set_num_threads(4)
    torch.set_num_interop_threads(4)
    queries = read_jsonl(args.dataset / "queries.jsonl")
    corpus = read_jsonl(args.dataset / "corpus.jsonl")
    digest = hashlib.sha256()
    for name in ["queries.jsonl", "corpus.jsonl"]:
        digest.update((args.dataset / name).read_bytes())
    for row in corpus:
        digest.update(Path(row["audio_path"]).read_bytes())
    model_id, revision = MODELS[args.model]
    signature = {
        "model": model_id, "revision": revision, "device": args.device,
        "dtype": "float32", "inputs_sha256": digest.hexdigest(),
        "runner_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "versions": {name: importlib.metadata.version(name) for name in
                     ["torch", "transformers", "numpy", "soundfile", "librosa"]},
        "platform": platform.platform(),
    }
    manifest = args.output / "manifest.json"
    if manifest.exists() and json.loads(manifest.read_text()) != signature:
        raise ValueError("Output contains a different run. Choose a new output directory.")
    manifest.write_text(json.dumps(signature, indent=2) + "\n")
    started = time.perf_counter()
    path = str(args.local_model) if args.local_model else snapshot_download(
        model_id, revision=revision,
        allow_patterns=["*.json", "*.safetensors", "*.bin", "*.txt", "*.model", "*.jinja", "*.py"],
        ignore_patterns=["onnx/*", "openvino/*", "pytorch_model.bin"] if args.model != "clap" else None,
    )
    # Jina's pinned modeling file is reviewed separately; no vLLM is installed.
    if args.model == "clap":
        model = ClapModel.from_pretrained(path).eval().to(args.device)
        processor = ClapProcessor.from_pretrained(path)
    else:
        model = AutoModel.from_pretrained(
            path, trust_remote_code=args.model == "jina", dtype=torch.float32,
            **({"modality": "audio", "attn_implementation": "sdpa"} if args.model == "jina" else {}),
        ).eval().to(args.device)
        tokenizer = AutoTokenizer.from_pretrained(path, trust_remote_code=args.model == "jina")
        extractor = WhisperFeatureExtractor(feature_size=128) if args.model == "jina" else None
    model.requires_grad_(False)
    synchronize(args.device)
    load_seconds = time.perf_counter() - started
    print(json.dumps({"model": args.model, "load_seconds_including_download": load_seconds}), flush=True)

    def normalize(value):
        return torch.nn.functional.normalize(value.float(), dim=-1).cpu().numpy()

    def encode_text(text, query):
        if args.model == "clap":
            inputs = processor(text=[text], return_tensors="pt", padding=True, truncation=True).to(args.device)
            value = model.get_text_features(**inputs)
            return normalize(value.pooler_output if hasattr(value, "pooler_output") else value)
        prefix = ("Query: " if query else "Document: ") if args.model == "jina" else ("query: " if query else "passage: ")
        inputs = tokenizer(prefix + text, return_tensors="pt", truncation=True,
                           max_length=8192 if args.model == "jina" else 512).to(args.device)
        if args.model == "jina":
            return normalize(model.embed(**inputs))
        hidden = model(**inputs).last_hidden_state
        mask = inputs["attention_mask"].unsqueeze(-1)
        return normalize((hidden * mask).sum(1) / mask.sum(1))

    def encode_audio(row):
        pcm, sr = sf.read(row["audio_path"], dtype="float32", always_2d=True)
        pcm = pcm.mean(axis=1)
        if sr != 16000 or len(pcm) > sr * 30 + 1 or not np.isfinite(pcm).all():
            raise ValueError("Expected finite mono 16 kHz audio of at most 30 seconds.")
        if args.model == "clap":
            import librosa
            # Preserve all evidence, rather than a random 10-second crop.
            chunks = [pcm[i:i + sr * 10] for i in range(0, len(pcm), sr * 10)]
            vectors = []
            for chunk in chunks:
                wave = librosa.resample(chunk, orig_sr=sr, target_sr=48000)
                inputs = processor(audio=wave, sampling_rate=48000, return_tensors="pt").to(args.device)
                value = model.get_audio_features(**inputs)
                vectors.append(normalize(value.pooler_output if hasattr(value, "pooler_output") else value))
            return np.concatenate(vectors)
        feats = extractor(pcm, sampling_rate=sr, return_tensors="pt", padding="max_length",
                          return_attention_mask=True)
        real = int(feats["attention_mask"].sum())
        count = ((real - 1) // 2 + 1 - 2) // 2 + 1
        cfg = model.config
        audio_run = (tokenizer.convert_ids_to_tokens(cfg.audio_start_token_id)
                     + tokenizer.convert_ids_to_tokens(cfg.audio_token_id) * count
                     + tokenizer.convert_ids_to_tokens(cfg.audio_end_token_id))
        prompt = tokenizer.apply_chat_template(
            [{"role": "user", "content": "Document: " + audio_run}],
            tokenize=False, add_generation_prompt=False,
        )
        inputs = tokenizer(prompt, return_tensors="pt").to(args.device)
        return normalize(model.embed(**inputs, input_features=feats["input_features"].to(args.device),
                                     feature_attention_mask=feats["attention_mask"].to(args.device)))

    tasks = [("query", q["query_id"], q) for q in queries]
    if args.model != "clap":
        tasks += [("transcript", c["segment_id"], c) for c in corpus]
    if args.model != "e5":
        tasks += [("audio", c["segment_id"], c) for c in corpus]
    for index, (kind, key, row) in enumerate(tasks):
        dest = args.output / f"{kind}-{key}.npz"
        if dest.exists():
            continue
        synchronize(args.device)
        before = time.perf_counter()
        with torch.inference_mode():
            value = encode_audio(row) if kind == "audio" else encode_text(
                row["query"] if kind == "query" else row["transcript_evidence"], kind == "query")
        synchronize(args.device)
        seconds = time.perf_counter() - before
        if not np.isfinite(value).all() or not np.allclose(np.linalg.norm(value, axis=1), 1, atol=1e-4):
            raise ValueError("Invalid embedding.")
        temporary = dest.with_suffix(".partial.npz")
        np.savez(temporary, embedding=value, seconds=seconds)
        temporary.replace(dest)
        print(json.dumps({"completed": index + 1, "total": len(tasks), "kind": kind, "seconds": seconds}), flush=True)
    (args.output / "complete.json").write_text(json.dumps({
        "load_seconds_including_download": load_seconds, "elapsed_seconds": time.perf_counter() - started,
        "tasks": len(tasks),
    }, indent=2) + "\n")


if __name__ == "__main__":
    main()
