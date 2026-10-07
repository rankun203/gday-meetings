"""Prepare pinned Granite transcript encoders for local Core ML inference.

Run with the locked environment in tools/semantic-model-conversion. Inputs are public
checkpoints; validation uses synthetic text only. No upload is performed.
"""

import argparse
import hashlib
import importlib.metadata
import json
import shutil
import subprocess
import time
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from huggingface_hub import snapshot_download
from transformers import AutoModel, AutoTokenizer

MODELS = {
    "97m": ("ibm-granite/granite-embedding-97m-multilingual-r2", "835ad14087e140460703cf0fae09f97d469d65c2"),
    "311m": ("ibm-granite/granite-embedding-311m-multilingual-r2", "44399559930365213510b1ee2eb15ded83374f0e"),
}
PROBES = [
    "Which release date did the team agree on?",
    "Alex proposed Monday. Sam corrected the date to Friday, and the team agreed.",
    "会议最后决定什么时候发布？",
    "最初建议周一发布，讨论后改为周五。",
    "Budget review",
    "The team discussed a supplier but did not choose one.",
]


class Encoder(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, input_ids, attention_mask):
        hidden = self.model(input_ids=input_ids, attention_mask=attention_mask, return_dict=False)[0]
        return torch.nn.functional.normalize(hidden[:, 0, :], p=2, dim=-1)


def use_float16(op):
    return op.op_type not in {'select', 'add', 'softmax', 'layer_norm', 'reduce_l2', 'real_div'}


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model", choices=MODELS)
    parser.add_argument("output", type=Path)
    parser.add_argument("--cache", type=Path)
    parser.add_argument("--tokens", type=int, default=512)
    parser.add_argument("--precision", choices=["float16", "float32", "mixed_float16"], default="float32")
    parser.add_argument("--license-file", type=Path)
    args = parser.parse_args()
    if args.tokens not in (128, 256, 512):
        parser.error("Choose a validated conversion shape: 128, 256, or 512.")
    if args.output.exists() and any(args.output.iterdir()):
        parser.error("Use an empty output directory.")
    subprocess.run(["xcrun", "--find", "coremlcompiler"], check=True, capture_output=True)
    args.output.mkdir(parents=True, exist_ok=True)
    torch.set_num_threads(2)
    torch.manual_seed(0)
    model_id, revision = MODELS[args.model]
    source = Path(snapshot_download(
        model_id, revision=revision, cache_dir=args.cache,
        allow_patterns=["*.json", "*.safetensors", "*.txt", "*.model", "LICENSE*", "NOTICE*"],
        ignore_patterns=["onnx/*", "openvino/*"],
    ))
    tokenizer = AutoTokenizer.from_pretrained(source, local_files_only=True)
    model = AutoModel.from_pretrained(
        source, local_files_only=True, dtype=torch.float32, attn_implementation="eager",
    ).eval()
    model.config.reference_compile = False
    encoder = Encoder(model).eval()
    inputs = tokenizer(PROBES[0], return_tensors="pt", padding="max_length", max_length=args.tokens)
    example = (inputs["input_ids"], inputs["attention_mask"])
    with torch.no_grad():
        traced = torch.jit.trace(encoder, example, strict=True)
    converted = ct.convert(
        traced, convert_to="mlprogram", minimum_deployment_target=ct.target.macOS15,
        inputs=[ct.TensorType(name=name, shape=(1, args.tokens), dtype=np.int32)
                for name in ["input_ids", "attention_mask"]],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        compute_precision=(ct.transform.FP16ComputePrecision(op_selector=use_float16)
                           if args.precision == "mixed_float16" else
                           ct.precision.FLOAT16 if args.precision == "float16" else ct.precision.FLOAT32),
        compute_units=ct.ComputeUnit.CPU_ONLY,
    )
    converted.author = "IBM Granite; Core ML conversion"
    converted.license = "Apache-2.0"
    converted.short_description = f"Granite {args.model} multilingual R2, CLS pooling and L2 normalization"
    converted.save(str(args.output / "SemanticEncoder.mlpackage"))
    subprocess.run([
        "xcrun", "coremlcompiler", "compile", str(args.output / "SemanticEncoder.mlpackage"), str(args.output),
    ], check=True)
    tokenizer.save_pretrained(args.output)
    for path in source.iterdir():
        if path.is_file() and path.name.startswith(("LICENSE", "NOTICE")):
            shutil.copy2(path, args.output / path.name)
    validation = []
    probes = []
    for text in PROBES + ["A recorded discussion. " * 100]:
        encoded = tokenizer(text, return_tensors="pt", padding="max_length", max_length=args.tokens, truncation=True)
        with torch.no_grad():
            reference = encoder(encoded["input_ids"], encoded["attention_mask"]).numpy().reshape(-1)
        started = time.perf_counter()
        actual = converted.predict({key: encoded[key].numpy().astype(np.int32)
                                    for key in ["input_ids", "attention_mask"]})["embedding"].reshape(-1)
        cosine = float(np.dot(actual, reference) / (np.linalg.norm(actual) * np.linalg.norm(reference)))
        maximum_error = float(np.max(np.abs(actual - reference)))
        validation.append({"cosine": cosine, "maximum_error": maximum_error,
                           "seconds": time.perf_counter() - started})
        probes.append({"ids": encoded["input_ids"][0].tolist(),
                       "mask": encoded["attention_mask"][0].tolist(), "reference": reference.tolist()})
        if not np.isfinite(actual).all() or cosine < 0.9999 or maximum_error > 0.002:
            raise ValueError(f"Core ML parity failed: {validation[-1]}")
    (args.output / "validation-probes.json").write_text(json.dumps(probes) + "\n")
    # Apache attribution is retained even when the upstream snapshot has only
    # license metadata. This repository already carries the unmodified text.
    license_path = args.license_file or (Path(__file__).resolve().parents[1] / "licenses/Apache-2.0.txt")
    shutil.copy2(license_path, args.output / "LICENSE")
    (args.output / "README.md").write_text(
        "---\nlicense: apache-2.0\nbase_model: " + model_id
        + "\nlibrary_name: coreml\npipeline_tag: feature-extraction\n"
        + "title: Granite multilingual R2 Core ML conversion\ndate: 2026-10-06\n"
        + "status: conversion-validated\n---\n\n"
        + f"# Granite {args.model} multilingual R2 for Core ML\n\n"
        + f"Converted from IBM Granite revision `{revision}`. IBM and the upstream contributors retain "
        + "ownership of the original model. Distributed under Apache 2.0; see LICENSE.\n\n"
        + f"Uses {args.precision} weights, a fixed batch of 1 and {args.tokens} tokens, CLS pooling, "
        + "and L2 normalization. Supply int32 `input_ids` and `attention_mask`; the output is `embedding`. "
        + "Apply the included tokenizer without query or passage prefixes. Pad on the right. "
        + "Split longer passages before indexing; do not silently truncate search queries.\n\n"
        + "The folder contains a source mlpackage and compiled mlmodelc. Compiled artifacts were prepared "
        + "on this Mac; recompile the source package if required by another deployment environment. "
        + "Synthetic CPU parity measurements and file hashes are in semantic-model.json. "
        + "These checks do not establish retrieval quality or cross-platform tokenizer parity.\n\n"
        + "Reproduction: run convert_granite_coreml.py with the dependency versions in semantic-model.json "
        + "and full Xcode selected. Use --license-file to supply the included Apache 2.0 license.\n"
    )
    manifest = {
        "version": 1, "model": model_id, "revision": revision,
        "conversion": f"granite-cls-{args.precision}-v1", "dimensions": model.config.hidden_size,
        "maximumTokens": args.tokens, "paddingToken": tokenizer.pad_token_id,
        "queryPrefix": "", "passagePrefix": "", "pooling": "cls", "normalization": "l2",
        "validation": validation,
        "versions": {name: importlib.metadata.version(name)
                     for name in ["torch", "transformers", "coremltools", "numpy"]},
        "scriptSHA256": digest(Path(__file__)),
        "sourceFiles": [{"path": str(path.relative_to(source)), "sha256": digest(path)}
                        for path in sorted(source.rglob("*")) if path.is_file()],
        "files": [{"path": str(path.relative_to(args.output)), "bytes": path.stat().st_size, "sha256": digest(path)}
                  for path in sorted(args.output.rglob("*")) if path.is_file()],
    }
    (args.output / "semantic-model.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"output": str(args.output), "validation": validation}, indent=2), flush=True)


if __name__ == "__main__":
    main()
