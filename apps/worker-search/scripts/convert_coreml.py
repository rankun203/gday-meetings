"""Convert reviewed, pinned CLSP files offline; never download or publish assets."""

from __future__ import annotations

import argparse
import hashlib
import importlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

MODEL_REVISION = "30355ce67960e4cc1562e4e5fa154baf86a21430"
TOKENIZER_REVISION = "e2da8e2f811d1448a5b465c236feacd80ffbac7b"
MODEL_HASHES = {
    "configuration_clsp.py": "181355c3c43fa3c135b37c34197290e3d01ce1780d14ea9b3eb147e0aa75d949",
    "modeling_clsp.py": "645ff192b5819212c8273f49c4fe64aeadf4db5c0819f74b093baa8cf3f8451c",
    "modular_clsp.py": "669f65d8c05aad37496ce03a813d6710543979bfc4f614d49748f1028e82b4c0",
    "zipformer2.py": "f3c019cc90e2268c1aa62d55037c3887883620438578f23c7d59ba04ff76cc23",
    "config.json": "c8195b4a4e1c318253b2eb362165784b213e830703837c020c7d034211817af2",
    "model.safetensors": "7c8c461867815d86d42013b2f55ca79e9bb8ea9fa129f377c1bced9f8b66a743",
}
TOKENIZER_HASHES = {
    "config.json": "ef0185e2aae6e06c5f105a285006952c340e20c7dbf43c86ec82601b13fc45e9",
    "merges.txt": "1ce1664773c50f3e0cc8842619a93edc4624525b728b188a9e0be33b7726adc5",
    "tokenizer.json": "847bbeab6174d66a88898f729d52fa8d355fafe1bea101cf960dd404581df70e",
    "tokenizer_config.json": "994f46754c5bf4014f1aa92d34b1374319c3a6b3f702105cd5b742beaecd18ce",
    "vocab.json": "9e7f63c2d15d666b52e21d250d2e513b87c9b713cfa6987a82ed89e5e6e50655",
}
REQUIRED_VERSIONS = {
    "coremltools": "9.0", "numpy": "1.26.4", "torch": "2.7.0",
    "torchaudio": "2.7.0", "transformers": "4.57.3",
    "huggingface-hub": "0.36.0", "safetensors": "0.6.2",
}


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify(directory: Path, expected: dict[str, str]) -> None:
    for name, sha in expected.items():
        path = directory / name
        if not path.is_file() or digest(path) != sha:
            raise ValueError(f"Pinned file is missing or changed: {path}")


def replace_exact(source: str, old: str, new: str, count: int = 1) -> str:
    if source.count(old) != count:
        raise ValueError(f"Unexpected reviewed-source pattern: {old!r}")
    return source.replace(old, new)


def prepare_source(snapshot: Path, tokenizer: Path, target: Path) -> dict[str, str]:
    target.mkdir()
    (target / "__init__.py").write_text("")
    for name in MODEL_HASHES:
        if name == "model.safetensors":
            # Only the temporary read-only view points at the large original file.
            (target / name).symlink_to((snapshot / name).resolve())
        else:
            shutil.copyfile(snapshot / name, target / name)
    path = target / "modular_clsp.py"
    source = replace_exact(path.read_text(), "from torch.cuda.amp import custom_bwd, custom_fwd",
                           "from torch.amp import custom_bwd, custom_fwd")
    source = replace_exact(source, "@custom_fwd\n", '@custom_fwd(device_type="cuda")\n', 2)
    source = replace_exact(source, "@custom_bwd\n", '@custom_bwd(device_type="cuda")\n', 2)
    # Matches the upstream portable expression already provided for ONNX.
    source = replace_exact(source, "return torch.logaddexp(x, y)",
                           "return logaddexp_onnx(x, y)", 2)
    source = replace_exact(
        source,
        '    log_sum = (1.0 + x_offset.exp()).log().to(x.dtype)\n'
        '    log_sum = torch.where(log_sum == float("inf"), x_offset, log_sum)',
        '    log_sum = logaddexp_onnx(torch.zeros_like(x_offset), x_offset)', 2,
    )
    path.write_text(source)
    path = target / "modeling_clsp.py"
    source = replace_exact(path.read_text(), 'from_pretrained("roberta-base")',
                           f"from_pretrained({str(tokenizer.resolve())!r}, local_files_only=True)", 2)
    path.write_text(source)
    path = target / "zipformer2.py"
    source = replace_exact(
        path.read_text(),
        """                rows = torch.arange(start=time1 - 1, end=-1, step=-1)
                cols = torch.arange(seq_len)
                rows = rows.repeat(batch_size * num_heads).unsqueeze(-1)
                indexes = rows + cols
                pos_scores = pos_scores.reshape(-1, n)
                pos_scores = torch.gather(pos_scores, dim=1, index=indexes)""",
        """                rows = torch.arange(time1).unsqueeze(-1)
                cols = torch.arange(seq_len).unsqueeze(0)
                indexes = rows * (n - 1) + (time1 - 1) + cols
                pos_scores = torch.index_select(pos_scores.flatten(start_dim=2), 2, indexes.flatten())""",
    )
    path.write_text(source)
    return {name: digest(target / name) for name in MODEL_HASHES if name.endswith(".py")}


def write_json(path: Path, data: object) -> None:
    path.write_text(json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False) + "\n")


def export_branch(source: Path, output: Path, scratch: Path, precision: str, branch: str) -> None:
    import numpy as np
    import torch
    import coremltools as ct

    torch.set_num_threads(4)
    torch.manual_seed(0)
    # A complete reviewed package avoids Transformers' transitive dynamic-module
    # cache copying and never enables repository-provided AutoModel execution.
    sys.path.insert(0, str(source.parent))
    model_class = importlib.import_module(f"{source.name}.modeling_clsp").CLSPModel
    model = model_class.from_pretrained(
        str(source), local_files_only=True, dtype=torch.float32
    ).eval().model
    model.requires_grad_(False)

    class Text(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.encoder = model.text_encoder
            self.projection = model.text_projection
            self.transform = model.text_transform

        def forward(self, input_ids, attention_mask):
            value = self.encoder(input_ids=input_ids, attention_mask=attention_mask, return_dict=False)[1]
            return torch.nn.functional.normalize(self.transform(self.projection(value)), dim=-1).reshape(1, 512)

    class Audio(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.embed = model.encoder_embed
            self.encoder = model.encoder
            self.projection = model.audio_projection
            self.transform = model.audio_transform

        def forward(self, features, lengths):
            value, lens = self.embed(features, lengths)
            mask = torch.arange(value.shape[1]).unsqueeze(0) >= lens.unsqueeze(1)
            value, lens = self.encoder(value.permute(1, 0, 2), lens, mask)
            value = value.permute(1, 0, 2)
            mask = torch.arange(value.shape[1]).unsqueeze(0) >= lens.unsqueeze(1)
            value = value.masked_fill(mask.unsqueeze(-1), 0).sum(dim=1) / lens.unsqueeze(-1)
            return torch.nn.functional.normalize(self.transform(self.projection(value)), dim=-1).reshape(1, 512)

    threshold = 0.999 if precision == "float32" else 0.995
    report = {"passed": False, "cosineThreshold": threshold, "cases": [], "logitScale": float(model.logit_scale.exp())}
    wrapper = Text().eval() if branch == "text" else Audio().eval()
    # Drop the unused branch before tracing; the selected wrapper owns its modules.
    if branch == "text":
        model.encoder_embed = model.encoder = model.audio_projection = model.audio_transform = None
    else:
        model.text_encoder = model.text_projection = model.text_transform = None
    def fixture(length, kind="seeded-features"):
        if branch == "text":
            ids = torch.full((1, length), 42, dtype=torch.int32)
            ids[0, 0], ids[0, -1] = 0, 2
            return ids, torch.ones((1, length), dtype=torch.int32)
        if kind == "synthetic-waveform":
            # Deterministic tones, a chirp, amplitude changes, and silence
            # exercise realistic log-filter-bank ranges without private audio.
            samples = length * 160
            time = torch.arange(samples, dtype=torch.float32) / 16000
            duration = samples / 16000
            signal = (0.13 * torch.sin(2 * torch.pi * 173 * time)
                      + 0.07 * torch.sin(2 * torch.pi * 719 * time)
                      + 0.09 * torch.sin(2 * torch.pi * (91 * time + 1800 * time.square() / duration)))
            signal *= 0.55 + 0.45 * torch.sin(2 * torch.pi * 2.3 * time).square()
            signal[(time % 1.7) < 0.23] = 0
            features, lens = model.compute_fbank(signal.unsqueeze(0), torch.tensor([samples]))
            if features.shape != (1, length, 128):
                raise ValueError(f"Unexpected synthetic feature shape: {features.shape}")
            return features, lens.to(torch.int32)
        return torch.randn(1, length, 128), torch.tensor([length], dtype=torch.int32)

    if branch == "text":
        example = fixture(32)
        inputs = [ct.TensorType(name=name, shape=(1, ct.RangeDim(2, 512, 32)), dtype=np.int32)
                  for name in ["input_ids", "attention_mask"]]
        lengths = [2, 32, 512]
        name = "CLSPText"
    else:
        example = fixture(1000)
        for module in wrapper.modules():
            if type(module).__name__ == "CompactRelPositionalEncoding":
                module.extend_pe(torch.zeros(1600))
        inputs = [ct.TensorType(name="features", shape=(1, ct.RangeDim(25, 3000, 1000), 128)),
                  ct.TensorType(name="lengths", shape=(1,), dtype=np.int32)]
        lengths = [25, 73, 1000, 3000]
        name = "CLSPAudio"
    cases = [(length, "seeded-features" if branch == "audio" else "seeded-tokens") for length in lengths]
    if branch == "audio":
        cases += [(length, "synthetic-waveform") for length in
                  [25, 73, 1000, 2322, 2469, 2837, 2864, 2865, 2884, 2968, 3000]]
    for length, kind in cases:
        values = fixture(length, kind)
        with torch.no_grad():
            reference = wrapper(*values).numpy()
        case_name = f"{branch}-{kind}-{length}"
        np.savez(scratch / f"{case_name}.npz", reference=reference,
                 **{item.name: value.numpy() for item, value in zip(inputs, values)})
        report["cases"].append({"branch": branch, "length": length, "fixture": kind, "file": case_name})
    write_json(scratch / f"{branch}.json", report)
    # Reference inference finishes before conversion allocates its graph and weights.
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example, check_trace=False)
    converted = ct.convert(
        traced, inputs=inputs, outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=ct.precision.FLOAT32 if precision == "float32" else ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL, skip_model_load=True,
    )
    converted.short_description = f"CLSP {branch} encoder with projection and unit-L2 normalization"
    converted.author = "CLSP authors; Core ML conversion by Gday Meetings contributors"
    converted.license = "Apache-2.0; inherited RoBERTa assets MIT; see licenses/NOTICE.md"
    converted.user_defined_metadata.update({"clsp_revision": MODEL_REVISION, "precision": precision})
    package = output / f"{name}.mlpackage"
    converted.save(str(package))


def validate_branch(output: Path, scratch: Path, branch: str, policy: str) -> None:
    import numpy as np
    import coremltools as ct

    report = json.loads((scratch / f"{branch}.json").read_text())
    name = "CLSPText" if branch == "text" else "CLSPAudio"
    predictor = ct.models.MLModel(str(output / f"{name}.mlpackage"),
                                 compute_units=getattr(ct.ComputeUnit, policy))
    results = {"passed": False, "cosineThreshold": report["cosineThreshold"], "cases": []}
    for fixture in report["cases"]:
        with np.load(scratch / f"{fixture['file']}.npz") as data:
            reference = data["reference"]
            actual = predictor.predict({key: data[key] for key in data.files if key != "reference"})["embedding"]
        left, right = reference.astype(np.float64), actual.astype(np.float64)
        cosine = float(np.sum(left * right) / (np.linalg.norm(left) * np.linalg.norm(right)))
        case = {key: value for key, value in fixture.items() if key != "file"}
        case.update(computeUnits=policy, cosine=cosine,
                    maxAbsoluteError=float(np.max(np.abs(reference - actual))))
        results["cases"].append(case)
        write_json(output / f"validation-{branch}-{policy}.json", results)
        print(json.dumps(case), flush=True)
        if not np.isfinite(actual).all() or not np.isfinite(cosine) or cosine < report["cosineThreshold"]:
            raise ValueError(f"Conversion fidelity failed: {case}")
    results["passed"] = True
    write_json(output / f"validation-{branch}-{policy}.json", results)


def validate_activations(source: Path, output: Path) -> None:
    import numpy as np
    import torch
    import coremltools as ct

    sys.path.insert(0, str(source.parent))
    module = importlib.import_module(f"{source.name}.modular_clsp")
    values = torch.linspace(-1000, 1000, 2001, dtype=torch.float32)

    class Activations(torch.nn.Module):
        def forward(self, x):
            return torch.stack([module.SwooshLForward(x), module.SwooshRForward(x)])

    # Preserve the original eager overflow fallback as an independent oracle.
    expected = []
    for offset, constant in [(4.0, 0.035), (1.0, 0.313261687)]:
        shifted = values - offset
        total = (1 + shifted.exp()).log()
        total = torch.where(total == float("inf"), shifted, total)
        expected.append(total - 0.08 * values - constant)
    expected = torch.stack(expected).numpy()
    patched = Activations()(values).numpy()
    np.testing.assert_allclose(patched, expected, rtol=1e-6, atol=2e-5)
    traced = torch.jit.trace(Activations().eval(), values)
    converted = ct.convert(traced, inputs=[ct.TensorType(name="x", shape=values.shape)],
                           outputs=[ct.TensorType(name="activation")],
                           minimum_deployment_target=ct.target.macOS15,
                           compute_precision=ct.precision.FLOAT32, skip_model_load=True)
    with tempfile.TemporaryDirectory(prefix="clsp-activation-") as temporary:
        package = Path(temporary) / "Activation.mlpackage"
        converted.save(str(package))
        report = {"passed": False, "minimum": -1000, "maximum": 1000, "count": 2001,
                  "absoluteTolerance": 2e-5, "relativeTolerance": 1e-6, "cases": []}
        for policy in ["ALL", "CPU_ONLY"]:
            predictor = ct.models.MLModel(str(package), compute_units=getattr(ct.ComputeUnit, policy))
            actual = predictor.predict({"x": values.numpy()})["activation"]
            report["cases"].append({"computeUnits": policy,
                                    "maxAbsoluteError": float(np.max(np.abs(actual - expected)))})
            write_json(output / "activation-validation.json", report)
            np.testing.assert_allclose(actual, expected, rtol=1e-6, atol=2e-5)
            del predictor
        report["passed"] = True
        write_json(output / "activation-validation.json", report)


def export_models(source: Path, output: Path, scratch: Path, precision: str) -> dict:
    # Each stage exits before the next begins: no simultaneous PyTorch checkpoint,
    # trace, CPU model, and accelerated model remains resident during validation.
    script = str(Path(__file__).resolve())
    report = {"passed": False, "cosineThreshold": 0.999 if precision == "float32" else 0.995, "cases": []}
    subprocess.run([sys.executable, "-c",
                    "import runpy,sys; from pathlib import Path; m=runpy.run_path(sys.argv[1]); "
                    "m['validate_activations'](Path(sys.argv[2]),Path(sys.argv[3]))",
                    script, str(source), str(output)], check=True)
    for branch in ["text", "audio"]:
        subprocess.run([sys.executable, "-c",
                        "import runpy,sys; from pathlib import Path; m=runpy.run_path(sys.argv[1]); "
                        "m['export_branch'](Path(sys.argv[2]),Path(sys.argv[3]),Path(sys.argv[4]),sys.argv[5],sys.argv[6])",
                        script, str(source), str(output), str(scratch), precision, branch], check=True)
        reference = json.loads((scratch / f"{branch}.json").read_text())
        report["logitScale"] = reference["logitScale"]
        for policy in ["ALL", "CPU_ONLY"]:
            subprocess.run([sys.executable, "-c",
                            "import runpy,sys; from pathlib import Path; m=runpy.run_path(sys.argv[1]); "
                            "m['validate_branch'](Path(sys.argv[2]),Path(sys.argv[3]),sys.argv[4],sys.argv[5])",
                            script, str(output), str(scratch), branch, policy], check=True)
            results = json.loads((output / f"validation-{branch}-{policy}.json").read_text())
            report["cases"].extend(results["cases"])
            write_json(output / "conversion-validation.json", report)
        name = "CLSPText" if branch == "text" else "CLSPAudio"
        subprocess.run(["xcrun", "coremlcompiler", "compile", str(output / f"{name}.mlpackage"), str(output)], check=True)
    report["passed"] = True
    report["scope"] = "Seeded encoder inputs and synthetic waveforms through upstream filter banks; not end-to-end Swift DSP/tokenizer or retrieval-quality validation"
    return report


def write_manifests(output: Path) -> None:
    runtime = []
    for path in sorted(output.rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(output)
        if (relative.parts[0] in {"CLSPAudio.mlmodelc", "CLSPText.mlmodelc", "licenses"}
                or str(relative) in TOKENIZER_HASHES):
            runtime.append({"path": str(relative), "bytes": path.stat().st_size, "sha256": digest(path)})
    write_json(output / "runtime-assets.json", {"schemaVersion": 1, "files": runtime})
    assets = [{"path": str(path.relative_to(output)), "bytes": path.stat().st_size, "sha256": digest(path)}
              for path in sorted(output.rglob("*"))
              if path.is_file() and path.name != "distribution-manifest.json"]
    write_json(output / "distribution-manifest.json", {"schemaVersion": 1, "files": assets})


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", type=Path, required=True)
    parser.add_argument("--tokenizer", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--precision", choices=["float32", "float16"], default="float32")
    parser.add_argument("--verify-only", action="store_true", help="Verify hashes and source adaptations without importing models")
    args = parser.parse_args()
    output = args.output.resolve()
    if any(output.is_relative_to(path.resolve()) for path in [args.snapshot, args.tokenizer]):
        raise ValueError("Output must stay outside the original snapshot and tokenizer directories.")
    verify(args.snapshot, MODEL_HASHES)
    verify(args.tokenizer, TOKENIZER_HASHES)
    if args.output.exists():
        raise ValueError("Output must be a new directory; existing evaluation files are never overwritten.")
    with tempfile.TemporaryDirectory(prefix="clsp-coreml-source-") as temporary:
        work = Path(temporary)
        patched = prepare_source(args.snapshot, args.tokenizer, work / "reviewed_clsp")
        if args.verify_only:
            print(json.dumps({"verified": True, "patchedSourceSHA256": patched}, indent=2))
            return
        if sys.platform != "darwin" or sys.version_info[:2] != (3, 12):
            raise ValueError("Full conversion requires macOS and the pinned Python 3.12 environment.")
        subprocess.run(["xcrun", "--find", "coremlcompiler"], check=True, capture_output=True)
        versions = {name: importlib.metadata.version(name).split("+")[0] for name in REQUIRED_VERSIONS}
        if versions != REQUIRED_VERSIONS:
            raise ValueError(f"Use the pinned coreml conversion environment: {versions}")
        os.environ.update({"HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1",
                           "HF_HOME": str(work / "hf"), "HF_MODULES_CACHE": str(work / "modules")})
        args.output.mkdir(parents=True)
        report = export_models(work / "reviewed_clsp", args.output, work, args.precision)
    for name in TOKENIZER_HASHES:
        shutil.copyfile(args.tokenizer / name, args.output / name)
    repository = Path(__file__).resolve().parents[3]
    licenses = repository / "apps/client-macos-swift/ThirdParty/clsp-licenses"
    shutil.copytree(licenses, args.output / "licenses")
    write_json(args.output / "conversion-validation.json", report)
    write_json(args.output / "conversion.json", {
        "schemaVersion": 1, "repository": "rankun203/yfyeung-clsp-coreml", "published": False,
        "upstreamModel": "yfyeung/CLSP", "modelRevision": MODEL_REVISION,
        "tokenizerModel": "FacebookAI/roberta-base", "tokenizerRevision": TOKENIZER_REVISION,
        "precision": args.precision, "tools": versions,
        "toolchain": {
            "python": platform.python_version(), "macOS": platform.mac_ver()[0],
            "architecture": platform.machine(),
            "xcode": subprocess.run(["xcodebuild", "-version"], check=True, capture_output=True, text=True).stdout.strip(),
        },
        "sourceSHA256": MODEL_HASHES, "tokenizerSHA256": TOKENIZER_HASHES,
        "patchedSourceSHA256": patched,
        "inputs": {"audio": {"features": [1, "25...3000", 128], "lengths": [1]},
                   "text": {"input_ids": [1, "2...512"], "attention_mask": [1, "2...512"]}},
        "outputs": {"embedding": [1, 512]},
        "modifications": ["torch.amp decorator migration", "offline local tokenizer/configuration",
                          "stable primitive logaddexp", "overflow-safe Swoosh forward activations", "shape-derived padding masks", "precomputed positional table",
                          "equivalent flattened relative-position indexes", "explicit batch-one output shape"],
    })
    (args.output / "README.md").write_text(f'''---
license: apache-2.0
base_model: yfyeung/CLSP
library_name: coreml
pipeline_tag: feature-extraction
date: 2026-10-06
status: prepared-not-published
---

# CLSP for Core ML

Prepared locally for `rankun203/yfyeung-clsp-coreml`; no upload is performed by this script.
Derived from CLSP `{MODEL_REVISION}` with pinned RoBERTa tokenizer `{TOKENIZER_REVISION}`.
Precision: `{args.precision}`. The complete text and audio encoders return 512-dimensional unit-L2 embeddings.
See `conversion.json` for input shapes, source hashes, tools, and conversion modifications.

Audio inputs are Kaldi filter-bank features, not raw PCM or Whisper log-mel features.
Use the matching Swift frontend with 16 kHz mono audio. Text inputs use case-sensitive RoBERTa byte BPE,
BOS 0, EOS 2, PAD 1, and a maximum of 512 tokens including special tokens.
The supplied `.mlmodelc` directories were compiled by the local Xcode toolchain;
`.mlpackage` files are included for recompilation on other supported toolchains.

`conversion-validation.json` reports seeded encoder parity with a predefined minimum cosine
of {report['cosineThreshold']}. This is not an evaluation of meeting-topic retrieval, native preprocessing,
or demographic accuracy. CLSP describes speaking style. See separate end-to-end evaluation results.

Retain `licenses/`, including Apache 2.0, inherited RoBERTa MIT, and native DSP BSD notices.
Please cite the upstream CLSP paper listed in `licenses/NOTICE.md`. No demonstration audio is included.
''')
    write_manifests(args.output)
    print(f"Prepared {args.output}; no files uploaded.", flush=True)


if __name__ == "__main__":
    main()
