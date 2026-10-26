---
title: Global voice clustering experiment
date: 2026-10-25
status: listening-review
scope: offline-voice-grouping-comparison
---

# Global voice clustering experiment

Compare global voice grouping across five embedding models on the same complete speech evidence. The app’s saved result remains a separate reference method. Review recordings, transcript assignments, group membership, sensitivity settings, arrival replays, and resource receipts without changing the running app or People Library.

## Five-model comparison

Compare five embedding models on the same independently detected speech windows, with the app’s saved result as a sixth review method. The five extraction runs use one canonical 16 kHz mono audio preparation and the same physical contexts. Every eligible window remains represented, including aliases of the same physical support. No per-person sample cap applies.

| Run name | Adapter module | Model ID |
| --- | --- | --- |
| `wespeaker` | `wespeaker_coreml_adapter` | `community1-wespeaker-coreml` |
| `redimnet_b6` | `redimnet_adapter` | `redimnet2_b6_vb2_vox2_lm` |
| `redimnet_b3` | `redimnet_adapter` | `redimnet2_b3_vb2_vox2_cnc2_lm` |
| `eres2netv2` | `eres_cam_adapter` | `eres2netv2-w24s4ep4` |
| `campplus` | `eres_cam_adapter` | `wespeaker-campplus-lm` |

**Current · Saved App Result** shows the app’s saved transcript identities; its numerical sample metrics use the retained saved-example replay. The fresh WeSpeaker run reruns the installed embedding graph on canonical audio. These distinguish saved behavior, canonical embedding inference, and global clustering. The comparison does not rerun the app’s complete recording, transcription, diarization, person association, and persistence workflow.

### Obtain model code and weights

Run from the repository root on macOS. Keep model downloads, code checkouts, receipts, and private fixtures under ignored `tmp/`. Use the saved-example baseline and complete full-speech input prepared in the archived workflow below. `ffmpeg`, the installed Community-1 compiled models, and a local Python environment are required. Adapters load supplied files and never upload recordings.

The [official ReDimNet2 repository](https://github.com/PalabraAI/redimnet2) and weights use MIT licensing. The requested B6 checkpoint is the VoxBlink2 + VoxCeleb2 large-margin release; the B3 checkpoint adds CN-Celeb2. The [3D-Speaker source](https://github.com/modelscope/3D-Speaker) and [ERes2NetV2 model card](https://www.modelscope.cn/models/iic/speech_eres2netv2w24s4ep4_sv_zh-cn_16k-common) declare Apache 2.0. [WeSpeaker source](https://github.com/wenet-e2e/wespeaker) uses Apache 2.0. The [CAM++ checkpoint card](https://huggingface.co/Wespeaker/wespeaker-voxceleb-campplus-LM) declares Apache 2.0, while WeSpeaker’s [pretrained-model documentation](https://github.com/wenet-e2e/wespeaker/blob/master/docs/pretrained.md) also identifies CC BY 4.0 terms for VoxCeleb pretrained weights. Retain both notices with that checkpoint. Use the installed Community-1 distribution’s license notices for its compiled models.

```sh
study_root=tmp/model-study
source_root=tmp/full-speech-study
baseline_root=tmp/saved-example-study
export UV_CACHE_DIR="$study_root/uv-cache"
mkdir -p "$study_root/code" "$study_root/models/redimnet" "$study_root/models/eres2net" "$study_root/models/campplus"
git clone https://github.com/PalabraAI/redimnet2.git "$study_root/code/redimnet2"
git -C "$study_root/code/redimnet2" checkout c5bbe0b76e37df698c403f8844e41304ceab6307
git clone https://github.com/modelscope/3D-Speaker.git "$study_root/code/3D-Speaker"
git -C "$study_root/code/3D-Speaker" checkout 065629c313eaf1a01c65c640c46d77e61e9607b4
git clone https://github.com/wenet-e2e/wespeaker.git "$study_root/code/wespeaker"
git -C "$study_root/code/wespeaker" checkout 9fecd6cb4f47475d01761d87c826298dff4ef18c
curl -L --fail -o "$study_root/models/redimnet/b6-vb2+vox2_v0-lm.pt" 'https://github.com/PalabraAI/redimnet2/releases/download/v1.0.0/b6-vb2+vox2_v0-lm.pt'
curl -L --fail -o "$study_root/models/redimnet/b3-vb2+vox2+cnc2_v0-lm.pt" 'https://github.com/PalabraAI/redimnet2/releases/download/v1.0.0/b3-vb2+vox2+cnc2_v0-lm.pt'
curl -L --fail -o "$study_root/models/eres2net/pretrained_eres2netv2w24s4ep4.ckpt" 'https://modelscope.cn/api/v1/models/iic/speech_eres2netv2w24s4ep4_sv_zh-cn_16k-common/repo?Revision=v1.0.1&FilePath=pretrained_eres2netv2w24s4ep4.ckpt'
uv run --no-project --with huggingface_hub hf download Wespeaker/wespeaker-voxceleb-campplus-LM avg_model.pt config.yaml \
  --revision c5e01c6fcffcce160861e7e79782828320192b5c --local-dir "$study_root/models/campplus"
```

The source revisions and model hashes belong to each run’s provenance. Record native Python, NumPy, PyTorch, and Torchaudio versions alongside each run; use separate environments for native inference and Core ML conversion.

### Prepare once and extract each model

`source_root/enriched-input.json` must be the original complete full-speech input, including a finite nonzero original embedding for every sample, its sibling `full-speech-manifest.json`, and an independent `library/` snapshot. Review coverage still reads the original embedding presence; candidate NPZ arrays do not replace that source field. The comparator rejects missing or invalid original embeddings. The variables above are generic destinations; supply your own isolated fixture locations. Generate five adapter configurations, supplying the directory containing installed `FBank.mlmodelc` and `Embedding.mlmodelc`:

```sh
uv run --no-project python - "$study_root" /path/to/installed/community1/models <<'PY'
import json
from pathlib import Path
import sys
root = Path(sys.argv[1]).resolve()
code, models = root / 'code', root / 'models'
configs = {
    'wespeaker': ('wespeaker_coreml_adapter', dict(model_id='community1-wespeaker-coreml', model_dir=sys.argv[2], device='coreml')),
    'redimnet_b6': ('redimnet_adapter', dict(model_id='redimnet2_b6_vb2_vox2_lm', model_dir=str(models/'redimnet'), code_dir=str(code/'redimnet2'), device='mps')),
    'redimnet_b3': ('redimnet_adapter', dict(model_id='redimnet2_b3_vb2_vox2_cnc2_lm', model_dir=str(models/'redimnet'), code_dir=str(code/'redimnet2'), device='mps')),
    'eres2netv2': ('eres_cam_adapter', dict(model_id='eres2netv2-w24s4ep4', model_dir=str(models/'eres2net'), code_dir=str(code/'3D-Speaker'), device='mps')),
    'campplus': ('eres_cam_adapter', dict(model_id='wespeaker-campplus-lm', model_dir=str(models/'campplus'), code_dir=str(code/'wespeaker'), device='mps')),
}
(root/'configs').mkdir(parents=True, exist_ok=True)
for name, (module, kwargs) in configs.items():
    (root/'configs'/f'{name}.json').write_text(json.dumps(dict(module=module, kwargs=kwargs), indent=2))
PY
mkdir -p "$study_root/receipts" "$study_root/prepared" "$study_root/runs"
measure_script=experiments/global-voice-clustering/measure.py
uv run --no-project --with psutil python "$measure_script" \
  --stage canonical-audio --output "$study_root/receipts/prepare-01.json" --stdout-log "$study_root/receipts/prepare-01.log" \
  --directory "$study_root/prepared" -- uv run --no-project --with numpy python \
  experiments/global-voice-clustering/model_extract.py prepare --input "$source_root/enriched-input.json" --output "$study_root/prepared"
```

Preparation verifies original audio hashes and exact decoded frame counts against the VAD manifest. It preserves embedding contexts and speech-only support separately. Unique physical jobs are deduplicated without dropping their observation aliases. Store a copy of the harness source with the preparation receipt when retaining a reproducible run.

Measure extraction sequentially so concurrent models do not compete for the same GPU. The baseline uses a Torch-free process; the four candidate models use their official PyTorch feature pipelines and MPS backbones. Set a candidate configuration’s `device` to `cpu` for a CPU run and use a new output directory.

```sh
mkdir -p "$study_root/runs/wespeaker"
uv run --no-project --with psutil python "$measure_script" \
  --stage embeddings-wespeaker --output "$study_root/receipts/wespeaker-01.json" --stdout-log "$study_root/receipts/wespeaker-01.log" \
  --directory "$study_root/runs/wespeaker" -- uv run --no-project --with numpy --with coremltools python \
  experiments/global-voice-clustering/model_extract.py extract --prepared "$study_root/prepared/prepared.json" \
  --output "$study_root/runs/wespeaker" --adapter-config "$study_root/configs/wespeaker.json" --batch-size 8
for name in redimnet_b6 redimnet_b3 eres2netv2 campplus; do
  mkdir -p "$study_root/runs/$name"
  uv run --no-project --with psutil python "$measure_script" \
    --stage "embeddings-$name" --output "$study_root/receipts/$name-01.json" --stdout-log "$study_root/receipts/$name-01.log" \
    --directory "$study_root/runs/$name" -- uv run --no-project --with numpy --with scipy --with torch --with torchaudio --with einops python \
    experiments/global-voice-clustering/model_extract.py extract --prepared "$study_root/prepared/prepared.json" \
    --output "$study_root/runs/$name" --adapter-config "$study_root/configs/$name.json" --batch-size 8
done
```

Equal-length contexts share a batch; extraction adds no padding to equalize different lengths. Successful batches are checkpointed atomically. Retrying the same configuration resumes completed batches and rejects changed inputs, code, weights, or checkpoints. `--limit N` is an explicit benchmark that never publishes complete embeddings. Use a separate directory for a benchmark and new receipt/log names for every attempt. Retain failed and interrupted measurement receipts.

Only a complete run publishes `embeddings.npz` with `ids`, normalized `embeddings`, and scalar `model_id`. `summary.json` records completion and coverage. `extraction-provenance.json` binds the adapter, model metadata, and canonical plan. External `measure.py` receipts provide elapsed time, CPU time, process and sampled process-tree resident memory, and apparent disk growth. Hash verification and checkpoint I/O are part of measured extraction. Environment installation contributes to a measured `uv run` if packages are cold; prepopulate an environment for inference-only measurements and record that choice. GPU or Neural Engine memory, energy, and accelerator assignment remain unmeasured.

### Compare and review

Build a JSON array of model descriptors. Each entry requires the following fields; `short_label` is optional:

```json
{
  "id": "global_dbscan_example",
  "label": "Example Model",
  "expected_model_id": "example-model-id",
  "embeddings": "tmp/model-study/runs/example/embeddings.npz",
  "summary": "tmp/model-study/runs/example/summary.json",
  "prepared": "tmp/model-study/prepared/prepared.json",
  "provenance": "tmp/model-study/runs/example/extraction-provenance.json"
}
```

Generate all five entries and run comparison:

```sh
uv run --no-project python - "$study_root" <<'PY'
import json
from pathlib import Path
import sys
root = Path(sys.argv[1]).resolve()
entries = []
for name, label in [('wespeaker','WeSpeaker'), ('redimnet_b6','ReDimNet2 B6'), ('redimnet_b3','ReDimNet2 B3'), ('eres2netv2','ERes2NetV2'), ('campplus','CAM++')]:
    run = root/'runs'/name
    config = json.loads((root/'configs'/f'{name}.json').read_text())
    entries.append(dict(id='global_dbscan_'+name, label=label, short_label=label,
        expected_model_id=config['kwargs']['model_id'],
        embeddings=str(run/'embeddings.npz'), summary=str(run/'summary.json'),
        prepared=str(root/'prepared/prepared.json'), provenance=str(run/'extraction-provenance.json')))
(root/'models.json').write_text(json.dumps(entries, indent=2))
PY
mkdir -p "$study_root/review"
uv run --no-project --with psutil python "$measure_script" \
  --stage model-comparison --output "$study_root/receipts/compare-01.json" --stdout-log "$study_root/receipts/compare-01.log" \
  --directory "$study_root/review" -- uv run --no-project --with numpy --with scipy python \
  experiments/global-voice-clustering/model_compare.py --input "$source_root/enriched-input.json" \
  --baseline-input "$baseline_root/enriched-input.json" --baseline-results "$baseline_root/results.json" \
  --models "$study_root/models.json" --output "$study_root/review"
cp -cR "$source_root/library" "$study_root/review/library"
# Start review.py after HDBSCAN attachment and paired-review preparation below.
```

The evaluator checks every descriptor before clustering: complete nonbenchmark coverage, matching requested/NPZ/model identity, identical canonical preparation hashes, exact original-input hashes, and matching physical support and sample bounds. `expected_model_id` binds the descriptor to its intended model when paths are configured. It rejects duplicate IDs and changes during evaluation. The final review input combines full-speech observations with the separate saved-example baseline. Keep resource receipts alongside the review bundle; `model_compare.py` does not automatically attach them to the UI.

The reference setting is cosine similarity 0.80 with three nonoverlapping embedding contexts per neighborhood. The five-model grid uses similarities 0.35, 0.45, 0.55, 0.65, 0.75, 0.80, 0.85, and 0.90, with minimum counts three and five. A sparse-graph edge cap can skip dense low thresholds; skipped settings remain recorded, and a default-setting overflow stops the model comparison. Meeting and sample arrival replays recompute grouping on arrived observations, retaining future aliases outside earlier checkpoints.

Cosine scores are not calibrated across these models. The same threshold can produce different false-match rates. Group size, grouped coverage, benchmark verification error, and runtime do not establish an accuracy winner. Use independent held-out listening judgments and per-model calibration before choosing a model or threshold. The saved app result provides a practical review reference; its retrospective sample metrics and historical identities have a different evidence domain from fresh full-speech extraction.

### Add HDBSCAN and matched density controls

Run clustering after the measured embedding and backend stages finish. `hdbscan_compare.py` reads the five complete NPZ runs from the same manifest; it does not rerun embeddings or change the original speech windows. Measure each model sequentially, retaining its shared-tree cache and every failed or interrupted receipt:

```sh
hdbscan_root="$study_root/hdbscan"
mkdir -p "$hdbscan_root" "$study_root/receipts"
for name in wespeaker redimnet_b6 redimnet_b3 eres2netv2 campplus; do
  uv run --no-project --with psutil python "$measure_script" \
    --stage "hdbscan-$name" --output "$study_root/receipts/hdbscan-$name-01.json" \
    --stdout-log "$study_root/receipts/hdbscan-$name-01.log" --directory "$hdbscan_root" -- \
    uv run --no-project --with hdbscan --with numpy --with scipy python \
    experiments/global-voice-clustering/hdbscan_compare.py run \
    --input "$source_root/enriched-input.json" --models "$study_root/models.json" \
    --model-key "$name" --output "$hdbscan_root" --mst-backend generic
done
uv run --no-project --with hdbscan --with numpy --with scipy python \
  experiments/global-voice-clustering/hdbscan_compare.py attach \
  --input "$source_root/enriched-input.json" --models "$study_root/models.json" \
  --output "$hdbscan_root" --review-root "$study_root/review" \
  --resource-receipt "$study_root/receipts/hdbscan-wespeaker-01.json" \
  --resource-receipt "$study_root/receipts/hdbscan-redimnet_b6-01.json" \
  --resource-receipt "$study_root/receipts/hdbscan-redimnet_b3-01.json" \
  --resource-receipt "$study_root/receipts/hdbscan-eres2netv2-01.json" \
  --resource-receipt "$study_root/receipts/hdbscan-campplus-01.json"
```

The primary HDBSCAN grid fits every unique physical context. Exact aliases share one fitted observation, while distinct overlapping windows can still increase density. **EOM** selects persistent clusters through excess of mass; **Leaf** selects finer branches from the condensed hierarchy. The grid holds minimum neighborhood density at three or five while varying minimum cluster size across five, ten, and twenty. Both selection methods are retained for every setting; the review default uses EOM, minimum cluster size five, and neighborhood density three. See the [official parameter guide](https://hdbscan.readthedocs.io/en/latest/parameter_selection.html) for the effects of these choices.

Vectors receive unit L2 normalization and use Euclidean distance, exactly `sqrt(2 * (1 - cosine similarity))`. This preserves neighbor ordering while changing the distance scale nonlinearly; HDBSCAN cluster stability therefore must not be described as equivalent to cosine-distance stability. The implementation uses [contrib HDBSCAN](https://hdbscan.readthedocs.io/en/latest/api.html). Its `min_samples` excludes self, so density three including self passes `min_samples=2`; density five passes four. Stock scikit-learn DBSCAN includes self. The [scikit-learn HDBSCAN notes](https://scikit-learn.org/stable/modules/generated/sklearn.cluster.HDBSCAN.html) document the implementation difference, and a synthetic MST regression verifies the installed contrib behavior.

The existing DBSCAN implementation counts nonoverlapping support within each neighborhood. HDBSCAN’s standard density rule differs. Secondary **Nonoverlapping Contexts** controls isolate that difference: earliest-finish interval selection chooses a maximum disjoint set separately for each physical recording, independent of model scores and person identity. HDBSCAN and stock DBSCAN fit exactly that same set. These controls use both HDBSCAN selection grids and DBSCAN similarities 0.65, 0.75, and 0.80 with densities three and five. Every omitted ID remains in assignments as `fit_role="overlap_omitted"`, with an explicit exclusion reason and `noise=null`; omissions are counted separately from algorithmic noise. This global anchor rule differs from the original neighborhood-specific rule, so retain both comparisons.

HDBSCAN uses an exact minimum spanning tree. The default `generic` backend computes dense Euclidean distances and was faster than implicit Prim’s in the synthetic backend probe. A conservative planning allowance is `3 × observations² × 8 + 2 × input-array bytes`, with a default six-GiB budget. This guard covers planned dense working arrays; it does not cap process RSS or include all runtime allocations. A run exceeding the allowance stops before fitting. Use `--mst-backend prims_kdtree` for the exact implicit-vector alternative, or explicitly raise `--max-dense-bytes` after checking available memory. Record the backend and actual measured memory with results; dense and implicit backends can differ at numerical ties.

Joblib caches shared tree computations under `cache/<model-key>/`. EOM, leaf, and cluster-size sweeps reuse a tree when their core-distance inputs match. Changing minimum density or the arrived cohort requires another tree. Preserve the cache when measuring the complete sweep; report a separate new-directory run for cold recomputation. The `fit_seconds` field includes cache lookup and assignment preparation, and external stage receipts include the entire sweep, variants, arrival refits, and checkpoint I/O. BLAS thread settings and background system work affect measured time.

Every complete model produces thirty variants: twelve primary HDBSCAN, twelve nonoverlap HDBSCAN, and six matched DBSCAN controls, subject to explicit sparse-graph limits on DBSCAN. Default EOM and leaf arrival replays are both stored for the primary and secondary cohorts; arrival checkpoints refit arrived evidence and can merge, split, or create groups. [Approximate prediction](https://hdbscan.readthedocs.io/en/latest/prediction_tutorial.html) holds an existing hierarchy fixed and is deliberately separate from these refits. `--benchmark` omits arrival work and cannot be attached as a complete run.

Attachment requires all five complete model results and verifies that their vectors, canonical preparation, and model identities match the existing DBSCAN comparison. It prevalidates every variant before copying. Identical files can be reused on a retry; changed existing variants require a new review directory, preserving the current review and feedback. Resource receipts remain available under `hdbscan_resources`.

Membership strength and cluster persistence are diagnostic signals rather than calibrated identity probabilities. HDBSCAN has no DBSCAN core/border classification, so its `core_samples` is unavailable. Report noise and omitted counts separately, inspect physical-observation co-membership churn on arrival, and use independent listening judgments for false merges and unnecessary splits. Optional `--labels PATH` accepts `{ "kind": "independent_listening", "source_input_sha256": "…", "labels": { "sample-a": "person-a" } }`; these labels score fitted physical observations only. Without independent labels, accuracy metrics remain unavailable. The paired review below provides reusable judgments across algorithms and settings.

### Prepare reusable listening pairs

Finish attaching all five models and both clustering families before preparing the pair queue. Use the same model manifest and review directory. Measure queue preparation separately from extraction and clustering:

```sh
uv run --no-project --with psutil python "$measure_script" \
  --stage listening-pairs --output "$study_root/receipts/pairs-01.json" \
  --stdout-log "$study_root/receipts/pairs-01.log" --directory "$study_root/review" -- \
  uv run --no-project --with numpy python experiments/global-voice-clustering/pair_review.py \
  --root "$study_root/review" --models "$study_root/models.json" --count 2000
uv run --no-project python experiments/global-voice-clustering/review.py \
  --root "$study_root/review" --port 8768
```

The builder requests up to 2,000 questions, targeting twenty percent seeded random controls and prioritizing the remaining pairs by disagreement. Group representatives and nearby embedding neighbors supply bounded candidates across models and settings. Each primary model/algorithm family receives equal total priority weight, divided equally among its settings, so a wider parameter sweep cannot gain more voting weight. Secondary density controls remain available in predictions and scores. These queue limits govern review effort; every extracted speech window remains in the underlying comparison.

One stable representative per physical density key prevents aliases from producing repeated questions or changing random-control weight. A pair cannot compare a context with itself, an exact alias, or overlapping embedding contexts from the same recording content. Pair identity is independent of model and setting, so one answer evaluates every configuration. Prioritized excerpts have at least one second of detected speech; random controls preserve the physical-context population, including short excerpts. The recorded seed makes control selection repeatable. Controls sample valid physical-context pairs rather than people uniformly.

The saved-app pair prediction requires complete unanimous transcript coverage of each sample’s detected speech. A full saved person identity can support comparisons across meetings. Local speaker identities require the same meeting and recording scope, with speaker ID or local label; matching local strings on different tracks do not establish identity. Partial, uncertain, conflicting, or unavailable coverage remains unresolved. Saved-app predictions are comparison evidence, separate from human identity judgments.

The builder checks the attached five-model/four-algorithm catalog and embedding hashes, verifies every variant through the catalog’s declared path and hash, and snapshots the review input, results, model manifest, and builder source. Changes during preparation prevent replacement of `results.json`. Queue preparation preserves feedback files and the underlying observations. Use a new measurement receipt for each retry.

In **Compare**, listen to voices A and B before revealing predictions. Choose **Same Person**, **Different People**, **Unsure**, or **Mixed Audio**. **Unsure** and **Mixed Audio** remain explicit exclusions from accuracy counts. A/B playback is exclusive, including a pending load; keyboard shortcuts offer playback, judgments, and pair navigation. The page warns when excerpts are short or may contain overlapping voices.

Names are shared across pairs. Existing passage corrections can supply an excerpt’s identity only when corrected passages cover all its detected speech and every contributing passage has the same nonempty name. These identities are read from current feedback rather than copied into a second label store. An explicit excerpt name overrides inherited names; clearing it is an explicit empty override. **Use Transcript Correction** restores inheritance. **Save Names**, **Clear Direct Answer**, and **Undo Review Change** support corrections without changing the app’s People Library. A direct same/different answer that conflicts with saved names is withheld from scoring until resolved. Group naming simulations and model-specific passage judgments retain their separate roles.

The judged-pair scoreboard shows known-same and known-different denominators, correct resolved predictions, false merges, unnecessary splits, unresolved predictions, and omitted fit contexts for every configuration. It distinguishes direct answers from name-derived judgments. Filter by model, algorithm, prioritized pairs, or seeded controls; enable density ablations to inspect the matched controls. Noise abstentions and overlap omissions remain separate, so a method cannot appear better merely by resolving more or fewer pairs.

The URL preserves the selected pair, queue and scoreboard filters, prediction reveal state, and paused pair-audio position. Back, Forward, and reload restore navigation without autoplay. Browser drafts, **Save Feedback**, revision-conflict handling, and **Export Feedback** retain their existing recovery behavior. Pair answers are shared across settings, so changing a clustering selection does not require answering the same acoustic question again.

Prioritized disagreements do not estimate population accuracy. Report seeded-control results separately, retain unreviewed and excluded denominators, and assess false merges, splits, abstentions, and arrival churn together. A larger group, stronger membership value, or greater resolved coverage does not establish an accuracy winner. Actual-browser checks on the completed dataset verified exclusive one-action playback, transcript-context navigation, EOM/leaf selection, global-group display, and paused Back restoration. Synthetic browser checks cover reusable names and the full-size configuration layout. Manual Save Feedback and Dismiss Notice checks were blocked by automatic approval review; automated temporary-server persistence tests passed. The worklog and results record these limits.

### Core ML conversion and resource measurements

`coreml_benchmark.py` exports a fixed-shape **feature-to-raw-embedding backbone**. Waveform feature extraction and output L2 normalization remain outside this export. Fixed 2-, 3-, and 5-second cases demonstrate those shapes; they do not establish arbitrary-duration or production app support.

The tested conversion environment uses Python 3.12, Core ML Tools 9.0, PyTorch/Torchaudio 2.7.0, and NumPy 1.26.4. These pins address converter compatibility: newer PyTorch lies outside that converter’s tested range, and the tested newer NumPy broke conversion. Keep conversion separate from a Torch-free runtime process. For example, convert ReDimNet2 B3:

```sh
export PYTHONPATH=experiments/global-voice-clustering
uv run --no-project --python 3.12 --with 'coremltools==9.0' --with 'torch==2.7.0' --with 'torchaudio==2.7.0' \
  --with 'numpy==1.26.4' --with scipy --with einops python experiments/global-voice-clustering/coreml_benchmark.py convert \
  --adapter redimnet_adapter --model-id redimnet2_b3_vb2_vox2_cnc2_lm \
  --model-dir "$study_root/models/redimnet" --code-dir "$study_root/code/redimnet2" \
  --output "$study_root/coreml/redimnet-b3-fp16" --seconds 2 3 5 --precision FLOAT16
uv run --no-project --python 3.12 --with 'coremltools==9.0' --with 'numpy==1.26.4' --with psutil python \
  experiments/global-voice-clustering/coreml_benchmark.py predict --output "$study_root/coreml/redimnet-b3-fp16" \
  --compute-units ALL --case-label synthetic-3s --run-label native-3s --repeats 10
```

Use the table’s candidate adapter/model IDs and corresponding model/code directories for the other three PyTorch models. Run each prediction case in a fresh process with a new run label. The installed WeSpeaker baseline already uses compiled Core ML graphs through `wespeaker_coreml_adapter.py`. Runtime measurements require native macOS model access; sandbox cache-permission failures must remain failed attempts in the record.

Conversion success and prediction parity are separate checks. Receipts retain TorchScript parity, package bytes, cold load, first prediction, warm predictions, sampled process memory, and cosine/relative-L2 differences from PyTorch. An FP16 parity failure requires a separate FLOAT32 conversion/output directory before drawing runtime conclusions. A successful FP32 conversion still requires prediction parity. `fixtures` can prepare reference features from a private local `--audio-npz`; `predict --fixtures-manifest PATH` checks those cases against existing fixed-shape packages. Keep private waveforms, feature fixtures, and labels under ignored `tmp/`.

Parameter storage estimates of `2 × parameters` for FP16 and `4 × parameters` for FP32 describe weight payload only. Actual package size also includes buffers and metadata. Resident memory includes runtime state and activations; process RSS excludes separate Core ML services and device allocations. Feature-backbone speed and numerical parity do not establish full-pipeline latency or speaker identity accuracy. Record unmeasured accelerator behavior and projection assumptions explicitly.

## Verify backends and measure the CPU frontend

`backend_benchmark.py` accepts the same adapter configuration files as extraction and an ignored NPZ containing mono 16 kHz float32 waveforms. Use representative authorized windows at 2, 3, and 5 seconds, with several windows per duration. Keep the NPZ and receipts under `tmp/`. Run these stages after extraction finishes so background model work does not affect timings.

```sh
export UV_CACHE_DIR=tmp/uv-cache
uv run --no-project --python 3.12 --with numpy==1.26.4 --with torch==2.7.0 \
  --with torchaudio==2.7.0 --with scipy --with einops --with psutil python \
  experiments/global-voice-clustering/backend_benchmark.py parity \
  --configs tmp/study/configs/model-a.json tmp/study/configs/model-b.json \
  --audio-npz tmp/study/private-windows.npz --output tmp/study/mps-parity.json
uv run --no-project --python 3.12 --with numpy==1.26.4 --with torch==2.7.0 \
  --with torchaudio==2.7.0 --with scipy --with einops --with psutil python \
  experiments/global-voice-clustering/backend_benchmark.py frontend \
  --configs tmp/study/configs/model-a.json tmp/study/configs/model-b.json \
  --audio-npz tmp/study/private-windows.npz --output tmp/study/frontend.json \
  --threads 4 --repeats 10
```

Run `parity` with normal macOS access. It disables MPS fallback, requires identical CPU frontend results, and compares raw CPU/MPS backbones plus normalized batch and individual outputs. The default acceptance criteria require cosine similarity at least 0.99999 and relative L2 error at most 0.005. A failed operation or threshold remains an explicit failure. These checks assess numerical agreement; they do not assess speaker accuracy.

During the ReDimNet2 B6 extraction, PyTorch MPS first batches at new feature-frame and batch-size combinations reached roughly 18 seconds in the later part of the run, while repeated combinations were much faster. The prepared workload contains hundreds of these combinations. This observed extraction cost belongs to the PyTorch MPS pipeline; it is separate from native Core ML specialization and prediction measurements. Record complete attempt costs rather than projecting full extraction time from warm batches alone.

The frontend stage measures each CPU waveform-to-feature operation independently. Its normalization timing uses a generic vector with the model's embedding dimension. Model loading is excluded from component latency. Wrap the commands with `measure.py` to retain process-resource receipts; those receipts include startup and model loading. Keep CPU frontend timing separate from the Torch-free Core ML runtime measurements.

## Attach model resource measurements

`model_resources.py` attaches flat `model_resources` and `coreml_resources` tables and resource receipts to an existing comparison. It preserves assignments, settings, and other review content. Supply every input explicitly:

```sh
uv run --no-project python experiments/global-voice-clustering/model_resources.py \
  --results tmp/study/review/results.json \
  --prepared tmp/study/prepared-audio/prepared.json \
  --models tmp/study/resource-models.json --frontend tmp/study/frontend.json \
  --output tmp/study/review/results.json
```

`resource-models.json` is an array with one entry per model. Paths resolve from the working directory. A measured installed pipeline needs `model_id`, `summary`, `extraction_receipt`, and `extraction_provenance`. A converted alternative can also provide the following fields:

```json
[
  {
    "model_id": "synthetic-embedder",
    "summary": "tmp/study/run/summary.json",
    "extraction_receipt": "tmp/study/resources/extract.json",
    "extraction_provenance": "tmp/study/run/extraction-provenance.json",
    "conversion": "tmp/study/coreml/conversion.json",
    "conversion_receipt": "tmp/study/resources/convert.json",
    "predictions": ["tmp/study/coreml/prediction-ALL-native-3s.json"],
    "prediction_receipts": ["tmp/study/resources/predict.json"],
    "private_fixtures": "tmp/study/coreml/fixtures-private.json",
    "private_prediction": "tmp/study/coreml/prediction-ALL-native-private.json"
  }
]
```

The attachment verifies extraction provenance and prepared-file hashes, complete coverage, checkpoint identity, prediction command and manifest bindings, and private numerical parity. Latest-attempt wall time remains separate from costs across all attempts; resumed or cached work cannot establish a complete fresh-run cost. The projection uses only a complete native-ALL private-window grid at 2, 3, and 5 seconds. Synthetic timings cannot fill missing private durations. A failed frontend receipt is rejected even when an individual model entry reports success. Failed or incomplete parity withholds timing recommendations and projections. Add repeated `--resource-receipt` arguments for failed or interrupted attempts and other measured stages so their costs remain visible.

Projections use the actual unique-job duration histogram. For each duration between 2 and 5 seconds, the script linearly interpolates measured medians and sums four-thread CPU frontend time, warm Core ML backbone time, and normalization time. It assumes serial processing and excludes batching, overlap, decoding, I/O, and model loading. Durations outside the measured range withhold the complete total. This estimates a hybrid prototype from measured components; it is not a native-app measurement.

Package size distinguishes one fixed-shape package from the sum of separately exported packages, which duplicate weights. The shared-weight payload is a parameter-only estimate: a flexible-shape production package has not been built. Conversion peak memory and runtime process memory remain separate. Process RSS excludes device allocations and separate Core ML or ANE services, including compilation work. Resource and numerical receipts retain their original source scope after later metadata-only adapter changes.

## Prepare required source evidence

The following commands prepare the isolated source evidence used by the five-model comparison. The review server accepts the current method catalog only. Earlier comparison outputs are offline preparation artifacts.

## Prepare the saved-example baseline

Use the repository root. Supply the actual library and installed Community-1 model directory as CLI arguments. Private outputs must be inside ignored `tmp/`. Snapshot preparation requires a new destination and refuses pending source transactions. It independently copies the latest 20 completed meetings and verifies source hashes and directory inventories before and after capture.

```sh
UV_CACHE_DIR=tmp/uv-cache uv run --no-project python experiments/global-voice-clustering/prepare.py --source /path/to/library --output tmp/global-voice-clustering
UV_CACHE_DIR=tmp/uv-cache uv run --no-project python experiments/global-voice-clustering/embed.py --input tmp/global-voice-clustering/input.json --models /path/to/community-1/models
UV_CACHE_DIR=tmp/uv-cache uv run --no-project --with numpy python experiments/global-voice-clustering/compare.py --input tmp/global-voice-clustering/enriched-input.json --output tmp/global-voice-clustering/results.json
```

## Run full-recording speech detection and comparison

Use the same isolated 20-meeting inventory as the baseline. The commands below make a second independent macOS clone, detect speech on every recording track, and measure each stage. Supply an existing Silero VAD ONNX model and the installed Community-1 models. `ffmpeg` must be available. The measured embedding stage includes job preparation, decoding, optimized Swift compilation, and inference.

```sh
export UV_CACHE_DIR=tmp/uv-cache
baseline_root=tmp/global-voice-clustering
study_root=tmp/global-voice-clustering-full-speech
receipt_root=tmp/global-voice-clustering-full-speech-resources
measure_script=experiments/global-voice-clustering/measure.py
mkdir -p "$study_root" "$receipt_root"
uv run --no-project --with psutil python "$measure_script" \
  --stage isolated-copy --output "$receipt_root/copy-01.json" --stdout-log "$receipt_root/copy-01.log" \
  --directory "$study_root" -- cp -cR "$baseline_root/library" "$study_root/library"
uv run --no-project --with psutil python "$measure_script" \
  --stage speech-detection --output "$receipt_root/vad-01.json" --stdout-log "$receipt_root/vad-01.log" \
  --directory "$study_root" -- uv run --no-project --with numpy --with onnxruntime python \
  experiments/global-voice-clustering/full_speech.py --root "$study_root" \
  --inventory "$baseline_root/input.json" --vad-model /path/to/silero-vad.onnx
uv run --no-project --with psutil python "$measure_script" \
  --stage embeddings --output "$receipt_root/embed-01.json" --stdout-log "$receipt_root/embed-01.log" \
  --directory "$study_root" -- uv run --no-project python \
  experiments/global-voice-clustering/embed.py --input "$study_root/input.json" --models /path/to/community-1/models
uv run --no-project --with psutil python "$measure_script" \
  --stage comparison --output "$receipt_root/compare-01.json" --stdout-log "$receipt_root/compare-01.log" \
  --directory "$study_root" -- uv run --no-project --with numpy --with scipy python \
  experiments/global-voice-clustering/full_compare.py --full "$study_root/enriched-input.json" \
  --baseline "$baseline_root/enriched-input.json" --baseline-results "$baseline_root/results.json" --output-root "$study_root"
uv run --no-project --with numpy --with scipy python experiments/global-voice-clustering/full_compare.py \
  --full "$study_root/enriched-input.json" --baseline "$baseline_root/enriched-input.json" \
  --baseline-results "$baseline_root/results.json" --output-root "$study_root" --resources-only \
  --resource-receipt "$receipt_root/copy-01.json" --resource-receipt "$receipt_root/vad-01.json" \
  --resource-receipt "$receipt_root/embed-01.json" --resource-receipt "$receipt_root/compare-01.json"
```

Use new receipt and log paths for each retry. Include failed and interrupted attempts with additional `--resource-receipt` arguments. `--resources-only` validates the existing input hashes and attaches receipts after comparison finishes; it preserves the measured assignments and avoids rerunning clustering. It replaces the attached collection with the supplied receipt list, so include every attempt to retain. Stage receipts record elapsed time, user and system CPU time, process peak resident memory, sampled process-tree memory when permitted, host details, and net apparent output growth. Missing measurements remain explicit. Shared memory, short-lived children, sampling, concurrent stages, and file clones limit attribution; GPU and Neural Engine activity, device memory, and energy are unavailable.

`full_compare.py` preserves the raw input as `full-speech-enriched.json`, writes the combined `review-input.json`, and records source hashes in `results.json`. The review verifies that combined input hash before serving. The primary configuration is predeclared: cosine similarity at least 0.8 and at least three nonoverlapping embedding contexts per neighborhood. Exact typed physical support counts once, and earliest-finish interval scheduling counts independent contexts within each physical recording. All windows remain available as core, border, or unresolved observations. A source-content hash also prevents aliases of the same recording from inflating density.

The offline sensitivity grid uses similarities 0.65, 0.70, 0.75, and 0.80 with minimum counts of three and five. It describes grouping changes; it does not establish a best setting. Meeting checkpoints recompute arrived evidence after 5, 10, 15, and 20 meetings. Sample checkpoints use up to eight batches ordered by meeting, speech start, and stable ID. Baseline meeting checkpoints filter the retained replay; sample checkpoints retain the full frozen baseline. These are descriptive replays because historical decision and arrival times are unavailable.

## Review

Open <http://127.0.0.1:8771> after starting the five-model review above. The initial layout follows the URL before data arrives. Compare loads pair evidence; transcript, full sample evidence, resources, and selected method assignments load when needed. Archived method fallbacks are removed. The Transcript view uses the app’s meeting list and timestamp, speaker, and text columns. Select a method above the transcript, click a passage to play, and judge its prediction on the right. Method judgments remain separate from shared person corrections. A persistent player supports All Tracks, individual tracks, seeking, playback speed, and paused-position restoration. All Tracks uses a cached local mix aligned to the selected audio offsets.

Timed blocks beneath each passage show chronological group assignments. Unclustered speech and uncovered gaps have distinct styles; multiple sequential groups remain separate from overlapping conflicting assignments. Click a block to play that recording interval and open its correction controls. Playback highlights the saved word or phrase timing and shows a moving marker within the current block. Untimed text retains passage highlighting. Text remains intact; clustering boundaries do not establish word alignment. Follow Playback keeps the current text and block visible, and suspends scrolling while editing. The selected interval and paused position are retained in the URL across method changes and reloads.

**Apply Person**, **Unclear**, and **Multiple Voices** record shared truth for the exact recording interval. **Wrong Group** records a judgment for the selected method and setting. **Clear Interval** removes annotations within the selected range while preserving neighboring corrections; **Undo** restores the previous edit. Predictions remain separate from corrections. Passage-level correction fields remain available. Interval annotations are saved and exported, but are excluded from the pair scoreboard until complete sample-support projection is available; passage-derived pair names are withheld when interval corrections could contradict them.

The reader uses current `transcript.jsonl` text and the app’s passage-grouping rules. It preserves constituent row identities, validates selected audio bindings, and shows partial or conflicting sample support explicitly. Meetings without a transcript remain available for recording playback.

Voice Groups uses the selected model and clustering settings and sorts largest groups first. Each group offers three excerpts, preferring different meetings and avoiding duplicate audio. **Play** loads and starts audio in one action; another player stops the previous one, including a pending load. **Meetings & Overview** combines the 20-meeting inventory with full recordings.

Enter a name and select **Name Group** or **Name & Next Unnamed** to simulate assigning every member to a person. Reuse a name across groups, undo a group name, or correct individual samples. **Use Group Name** removes a sample exception. This simulation leaves measured assignments and the People Library unchanged. Unclustered DBSCAN samples are hidden from group review initially; enable **Include Unclustered Samples** to review them. They lack enough neighborhood support under the selected settings and may join a group when new evidence arrives.

The URL preserves the view, method, meeting, filters, page, selected passage or sample, expanded sections, track, playback speed, scroll, and paused audio position. Back, Forward, and reload restore that location without autoplay. Names, notes, and unapplied naming fields are browser drafts; **Save Feedback** persists applied annotations in the private fixture's `feedback-<input-hash>.json`. **Export Feedback** includes annotations and unapplied drafts for recovery. Concurrent saves report a revision conflict, and differing browser drafts are retained for recovery. Keep the server running while reviewing.

For isolated UI verification, supply `--feedback-directory tmp/global-voice-clustering/review-validation` and a separate port. This preserves the real review's feedback and browser drafts.

`full_speech.py` detects activity independently on each track and retains every detected speech interval. Short intervals receive explicit context for the voice model. Voice activity detection (VAD) does not separate simultaneous speakers or guarantee one speaker per window. Coverage records detected speech, covered speech, embedding windows, exclusions, and extraction failures. Incomplete recording benchmarks do not publish `input.json`.

`embed.py` compiles an optimized standalone Swift executable using the app's production extractor, audio-preparation components, cached FluidAudio checkout, and locally built Opus libraries. It needs macOS, a Swift toolchain, those existing build dependencies, and installed `FBank.mlmodelc` and `Embedding.mlmodelc`. It does not download models. `ffmpeg` provides exact-range listening clips, seeking directly to each range and joining fragmented support without playing intervening speech. Clips use independent preparation locks so one uncached recording does not block other samples. It also decodes AAC inputs to float WAV at the original rate and channel count before the production resampler; source and decoded hashes are recorded.

`--max-jobs` supports an extraction benchmark. A partial benchmark does not publish `enriched-input.json`. Extraction can resume from its private result journal. The server refuses an input/result hash mismatch. Keep the immutable source snapshot and earlier feedback when preparing another round; use a new output directory for new source data.

## Validate

```sh
UV_CACHE_DIR=tmp/uv-cache uv run --no-project --with numpy --with scipy --with psutil --with torch --with torchaudio --with hdbscan python -m unittest discover -s experiments/global-voice-clustering -p 'test_*.py'
node --check experiments/global-voice-clustering/review.js
node --test experiments/global-voice-clustering/test_review_state.js
git diff --check
```

Read [RESULTS.md](RESULTS.md) for definitions, measurements, and limits. Fresh full-speech embeddings address saved-range selection bias. Human identity labels remain necessary to assess accuracy. This experiment evaluates independent speech activity and global voice grouping; it does not supply a production diarizer, persistence model, or accelerator profile.
