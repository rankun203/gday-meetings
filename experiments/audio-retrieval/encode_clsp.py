"""Encode the expanded private corpus with the pinned CLSP checkpoint."""

import argparse
import hashlib
import json
import time
from pathlib import Path

import numpy as np
import soundfile as sf
import torch
from transformers import AutoModel


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dataset", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--device", default="mps", choices=["cpu", "mps"])
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    queries = [
        json.loads(s) for s in (args.dataset / "queries.jsonl").read_text().splitlines()
    ]
    corpus = [
        json.loads(s) for s in (args.dataset / "corpus.jsonl").read_text().splitlines()
    ]
    digest = hashlib.sha256()
    for name in ["queries.jsonl", "corpus.jsonl"]:
        digest.update((args.dataset / name).read_bytes())
    for row in corpus:
        digest.update(Path(row["audio_path"]).read_bytes())
    signature = {
        "inputs_sha256": digest.hexdigest(),
        "revision": "30355ce67960e4cc1562e4e5fa154baf86a21430",
        "device": args.device,
        "runner_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    }
    manifest = args.output / "manifest.json"
    if manifest.exists() and json.loads(manifest.read_text()) != signature:
        raise ValueError("Run signature changed")
    manifest.write_text(json.dumps(signature, indent=2))
    torch.set_num_threads(2)
    torch.manual_seed(42)
    started = time.perf_counter()
    model = (
        AutoModel.from_pretrained(
            "yfyeung/CLSP",
            revision=signature["revision"],
            code_revision=signature["revision"],
            trust_remote_code=True,
            local_files_only=True,
        )
        .eval()
        .to(args.device)
    )
    model.requires_grad_(False)
    load = time.perf_counter() - started
    for kind, rows in [("query", queries), ("audio", corpus)]:
        for i, row in enumerate(rows):
            key = row["query_id"] if kind == "query" else row["segment_id"]
            dest = args.output / f"{kind}-{key}.npz"
            if dest.exists():
                continue
            before = time.perf_counter()
            with torch.inference_mode():
                if kind == "query":
                    _, embedding, _ = model(
                        text=[row["query"]], freeze_text_encoder=True
                    )
                else:
                    pcm, sr = sf.read(
                        row["audio_path"], dtype="float32", always_2d=True
                    )
                    assert sr == 16000
                    audio = torch.from_numpy(pcm.mean(axis=1)).unsqueeze(0)
                    # Preserve reference CPU filterbank extraction; accelerate the encoder only.
                    features, lengths = model.model.compute_fbank(
                        audio, torch.tensor([audio.shape[1]])
                    )
                    embedding = model.model.forward_audio_encoder(
                        features.to(args.device),
                        lengths.to(args.device),
                        freeze_encoder=True,
                    )
                    embedding = model.model.audio_transform(
                        model.model.audio_projection(embedding)
                    )
                    embedding = torch.nn.functional.normalize(embedding, dim=-1)
                value = embedding.cpu().numpy()
            assert np.isfinite(value).all() and np.allclose(
                np.linalg.norm(value, axis=1), 1, atol=1e-4
            )
            np.savez(dest, embedding=value, seconds=time.perf_counter() - before)
            if i % 25 == 0:
                print(kind, i + 1, len(rows), flush=True)
    q = np.concatenate(
        [
            np.load(args.output / f"query-{r['query_id']}.npz")["embedding"]
            for r in queries
        ]
    )
    c = np.concatenate(
        [
            np.load(args.output / f"audio-{r['segment_id']}.npz")["embedding"]
            for r in corpus
        ]
    )
    np.save(args.dataset / "reference-similarities.npy", q @ c.T)
    (args.output / "complete.json").write_text(
        json.dumps(
            {
                "load_seconds": load,
                "elapsed_seconds": time.perf_counter() - started,
                "queries": len(q),
                "windows": len(c),
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
