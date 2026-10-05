---
title: Reproduce the CLSP Core ML conversion
date: 2026-10-06
status: validated
scope: offline-clsp-model-conversion
---

# Reproduce the CLSP Core ML conversion

The conversion tool prepares model files locally. It never downloads models, uploads files, or replaces an existing output directory. App users do not need this Python environment; the Mac app runs the exported models through Swift and Core ML.

Use the separate conversion environment in this directory. It pins Core ML Tools 9.0, PyTorch and Torchaudio 2.7.0, Transformers 4.57.3, and Python 3.12. The original search-worker environment remains on PyTorch 2.8.0 for reference evaluation. Core ML Tools reports PyTorch 2.8.0 as untested, so it is not used for conversion. Dependency installation requires network access; the conversion itself is offline.

## Inputs

Obtain these complete, reviewed snapshots separately:

- [CLSP, 30355ce67960e4cc1562e4e5fa154baf86a21430](https://huggingface.co/yfyeung/CLSP/tree/30355ce67960e4cc1562e4e5fa154baf86a21430): `config.json`, the four Python modules, and `model.safetensors`.
- [RoBERTa-base, e2da8e2f811d1448a5b465c236feacd80ffbac7b](https://huggingface.co/FacebookAI/roberta-base/tree/e2da8e2f811d1448a5b465c236feacd80ffbac7b): `config.json`, `tokenizer_config.json`, `tokenizer.json`, `vocab.json`, and `merges.txt`.

The converter checks SHA-256 values before importing any model code. The checkpoint digest comes from the pinned Hugging Face LFS metadata; source and tokenizer digests identify the reviewed contents. It rejects missing or modified files. Do not alter the hash constants to make an unreviewed revision pass.

From the repository root, replace the example paths with local snapshot directories:

```sh
uv sync --project apps/worker-search/coreml
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
uv run --project apps/worker-search/coreml python apps/worker-search/scripts/convert_coreml.py \
  --snapshot /path/to/clsp-snapshot \
  --tokenizer /path/to/roberta-tokenizer \
  --output tmp/clsp-coreml-prepared \
  --verify-only
```

Remove `--verify-only` to export. The output directory must not exist, including after a failed export; choose a new path so failure evidence and active evaluation files remain available. Full export needs macOS with Xcode's `coremlcompiler`, several gigabytes of model memory, and enough disk space for both source packages and compiled models. The default is float32. `--precision float16` is an explicit experiment with a separate output directory; no weight quantization is performed.

## Reviewed adaptations

Only a temporary copy changes. The original snapshot and Hugging Face cache remain untouched. The copy migrates deprecated CUDA AMP decorators to `torch.amp` with `device_type="cuda"`, points tokenizer/configuration loading to the supplied offline directory, and expresses `logaddexp` using the equivalent stable primitive expression already supplied upstream for ONNX. The two Swoosh forward helpers use the same stable log-add-exp expression instead of computing an overflowing exponential and then replacing infinity. A separate float32 stress check compares both helpers over −1000…1000 against the original eager fallback and both Core ML compute policies, with fixed absolute tolerance 0.00002 and relative tolerance 0.000001. The audio wrapper uses tensor-shape-derived padding masks and precomputes the bounded positional table. Relative attention uses equivalent flattened indexes instead of a gather with an ambiguous flattened batch dimension; both encoder outputs explicitly reshape to `[1,512]`. This preserves the original index ordering while allowing Core ML to determine shapes during Metal compilation. Export keeps both learned projections, transforms, and final unit-L2 normalization. The text branch uses RoBERTa's learned pooler output, matching the released inference code.

Model input contracts are batch size one:

| Model | Inputs | Output |
| --- | --- | --- |
| `CLSPAudio` | Float32 `features[1,T,128]`, Int32 `lengths[1]`, 25 ≤ T ≤ 3000 | `embedding[1,512]` |
| `CLSPText` | Int32 `input_ids[1,L]` and `attention_mask[1,L]`, 2 ≤ L ≤ 512 | `embedding[1,512]` |

Audio features must come from the matching 16 kHz mono Kaldi filter-bank frontend; they are not interchangeable with Whisper features. Text must use the pinned case-sensitive byte-BPE tokenizer, including special tokens, truncation, attention masks, and leading-space behavior. The full native preprocessing tests compare those steps separately.

## Outputs and validation

Export and each compute-policy validation run in separate sequential processes to release checkpoints, traces, and runtime models between stages. The exporter drops the unused encoder branch and does not load Core ML while producing packages. The tool saves `.mlpackage` files and compiles `.mlmodelc` directories using `xcrun coremlcompiler`. It copies tokenizer assets and third-party licenses, writes a prepared model card for the future `rankun203/yfyeung-clsp-coreml` repository, and records source/tool versions and modifications in `conversion.json`. `runtime-assets.json` contains only compiled model files, tokenizer assets, and licenses needed by the app; it excludes the redundant source packages. `distribution-manifest.json` lists sorted relative paths, byte counts, and SHA-256 hashes of every generated file except itself. This deterministically describes the files produced; it does not assert that different Xcode versions produce byte-identical compiled models.

Seeded checks compare the converted encoders with the reviewed PyTorch export wrappers at text lengths 2, 32, and 512 and feature lengths 25, 73, 1000, and 3000. Additional deterministic mixtures of tones, chirps, amplitude changes, and silence pass through the upstream filter-bank frontend at lengths 25, 73, 1000, 2322, 2469, 2837, 2864, 2865, 2884, 2968, and 3000. These exercise realistic log-feature ranges and lengths implicated by corpus evaluation. The required minimum cosine similarity is fixed before execution: 0.999 for float32 and 0.995 for float16. Nonfinite results or a lower score fail conversion. The report includes maximum absolute error and identifies its limited scope. This does not replace comparison with the original PyTorch 2.8.0 model, end-to-end Swift preprocessing, realistic audio, or retrieval-quality evaluation.

The tool tests every shape using both `ALL` and `CPU_ONLY` compute-unit policies. An `ALL` pass confirms that policy can load and execute the model; it does not prove every operation ran on a GPU or Neural Engine. Device placement and performance need separate profiling. The float32 conversion, native preprocessing, and persisted search have been validated; results and remaining compiler diagnostics are recorded in the [integration worklog](../../../docs/worklogs/2026-10-06-clsp-coreml.md). The prepared distribution includes a sanitized `EVALUATION.md` report. Publication remains outside this task, and downloads need an immutable revision before release.

The current compiler can log a BNNS convolution shape-deduction diagnostic for the audio model's short variable-length range, including during CPU-model teardown. Direct compiled-model predictions passed at the declared minimum and representative longer lengths on both compute policies. A diagnostic copy whose lower bound was raised to 1000 compiled without that message; the distributed model retains the validated 25-frame minimum. Keep the warning visible and rerun compiled-model checks after compiler changes. See the integration worklog for the toolchain and results; this is not a warning-free conversion claim.
