---
title: Speaker embedding projector
date: 2026-10-08
status: experimental
scope: private-evidence-export
---

# Prepare production consolidation

Run these commands from the repository root on macOS. Keep replay outputs and source WAVs in an ignored input directory. Each manifest sample must have its verified `<id>-on/` replay directory and `<id>-on.run.json` receipt beside the manifest. Sources must be distinct and have zero time offset for this combination step.

```sh
mkdir -p tmp/projector-tools/module-cache
PROJECTOR_CORE=apps/client-macos-swift/Sources/GdayMeetings/Core
xcrun swiftc -O -parse-as-library \
  -module-cache-path tmp/projector-tools/module-cache \
  "$PROJECTOR_CORE/LocalModels/TypedVoiceEmbedding.swift" \
  "$PROJECTOR_CORE/VoiceEmbeddingMath.swift" \
  "$PROJECTOR_CORE/SpeakerEvidence.swift" \
  "$PROJECTOR_CORE/VoiceProfileSelection.swift" \
  "$PROJECTOR_CORE/SpeakerConsolidation.swift" \
  experiments/speaker-projector/Consolidate.swift \
  -o tmp/projector-tools/consolidate
uv run --no-project python experiments/speaker-projector/combine.py \
  --manifest tmp/projector-input/manifest.json \
  --runner tmp/projector-tools/consolidate
```

`combine.py` verifies replay completion, failures, artifact hashes, distinct source identities, and sample/label namespaces. It remaps the independent replay source names to their actual recording sources and runs the compiled production implementation. It writes `combined-evidence.json`, `combined-analysis.json`, separate result/audit files, and a provenance receipt without modifying the input meeting. Existing output files cause failure; use a fresh input workspace for another run.

# Export speaker evidence

This exporter prepares private, timed voice samples for Apple Embedding Atlas. It does not update meeting labels or the People Library. Inputs and generated audio, vectors, names, and reports stay in ignored `tmp/` directories.

```sh
uv run --no-project --with numpy --with umap-learn --with pyarrow --with soundfile \
  python experiments/speaker-projector/export.py \
  --manifest tmp/projector-input/manifest.json \
  --evidence tmp/projector-input/combined-evidence.json \
  --result tmp/projector-input/combined-result.json \
  --audit tmp/projector-input/combined-audit.json \
  --historical-examples tmp/projector-input/historical-examples.json \
  --historical-intervals tmp/projector-input/historical-intervals.json \
  --references-v2 tmp/projector-input/historical-evidence-v2.json \
  --output tmp/projector-output
```

The manifest lists source WAVs with `actualSource`, `audioPath`, `audioSHA256`, `durationSeconds`, and optional `timeOffsetSeconds`. Evidence, result, and audit use the production consolidation schemas. The audit must include the exact evidence SHA-256. Cluster membership must account for every replay sample exactly once, as clustered, invalid, or untrusted. The audit’s separate `untrustedSampleIDs` remains visible; saturated samples are never dropped from the plot. Representative ranks come directly from production `representativeSampleIDs`; they are selection order, not a calibrated quality score.

Historical examples contain reviewed excerpt metadata and a people dictionary. Only person IDs and names enter the export. Historical intervals contain `source`, `start`, `end`, and `speakerID`, with optional `personID`. These may be saved transcript-row labels rather than original model activity. Interval overlap is always labeled **Historical context, not ground truth**. It never assigns a person to a replay sample. Without an intervals file, context covers only the sparse retained historical examples.

Optional re-extracted references must match historical excerpt IDs, source, and timestamps. Only explicitly confirmed, nonexcluded, uncleared excerpts with a person assignment become named references. A name on a historical channel is insufficient. Other historical excerpts remain separate unnamed reference rows. Version 1 vectors must remain in a separate export; this script rejects mixing them into the corrected version 2 space.

# Inspect the output

The exporter writes `samples.parquet`, equivalent `samples.jsonl`, and a provenance/count/coverage `summary.json`. Every row has a WAV data URL for playback. No email, notes, or transcript text is exported.

```sh
uv run --no-project --with embedding-atlas embedding-atlas \
  tmp/projector-output/samples.parquet \
  --vector embedding --x projection_x --y projection_y --neighbors neighbors
```

Configure the `audio` column with Atlas's audio renderer. The [official data-format documentation](https://apple.github.io/embedding-atlas/data-formats.html) describes Parquet, JSONL, and audio data URLs. The [command-line documentation](https://apple.github.io/embedding-atlas/tool.html) defines precomputed coordinates and neighbors with zero-based row IDs. Disable automatic text labels when inspecting production cluster IDs; text labels do not represent speaker identities.

The projection uses cosine UMAP with seed 42, one job, and random initialization. Coordinates are exploratory; screen distance is not an identity score. Fewer than three rows receive zero coordinates instead of a misleading fitted map. Exact neighbors use cosine distance in the original normalized 256-dimensional space, excluding the row itself. Package versions and source hashes are recorded to reproduce a run. Hashes bind the exact parsed JSON bytes; JSON inputs, audio, and exporter source are checked again after calculations. Output is staged privately and published as a complete directory, so failure does not leave a partial export.

Nearest named-reference diagnostics compare each sample against confirmed excerpts and exclude overlapping audio from the same source. They report the best excerpt per person, best cosine, and the margin over the second person. They are **not calibrated or applied**. Sparse references, channel differences, overlap, and unrepresented people can make the nearest named person incorrect. Reference diagnostics do not change cluster membership or review state.

# Export and serve the configured viewer

The configured Atlas viewer preserves production clusters, disables automatic text labels, and includes a separate three-row timeline. Use a fresh site directory.

```sh
uv run --no-project --with embedding-atlas --with pandas --with pyarrow --with plotly \
  python experiments/speaker-projector/atlas.py \
  --export tmp/projector-output \
  --analysis tmp/projector-input/combined-analysis.json \
  --evidence tmp/projector-input/combined-evidence.json \
  --result tmp/projector-input/combined-result.json \
  --historical-intervals tmp/projector-input/historical-intervals.json \
  --historical-examples tmp/projector-input/historical-examples.json \
  --site tmp/projector-site \
  --audio-base-url http://127.0.0.1:8765/projector/audio/
uv run --no-project python -m http.server 8765 \
  --bind 127.0.0.1 --directory tmp/projector-site
```

Open `http://127.0.0.1:8765/projector/` for samples and `http://127.0.0.1:8765/timeline.html` for the timeline. The viewer stores audio in hash-named WAV files and queries short URLs, so filtering does not transfer every audio payload through the database. The canonical Parquet/JSONL export retains its self-contained data URLs. `--audio-base-url` must match the serving port and projector path; only HTTP loopback hosts are accepted. Moving the site to another port requires regenerating its viewer URLs. The server binds only to the local computer. Stop it with Control-C. The generated site includes private audio and names; keep it inside the ignored workspace.

The first timeline row shows saved transcript labels as historical context, the second shows fresh local activity and handoffs, and the third shows production consolidation intervals with selected sample markers. Production consolidation uses trusted local-label continuity and local-label embedding means; a cluster is not an independently verified person. It cannot detect every identity change inside one local label. “Cosine to label mean” includes that sample in the mean and describes consistency, not independent identification.

The viewer's 0.85 similarity / 0.08 margin gate is a diagnostic filter only. It is not calibrated on this meeting, not an estimated probability, and not an applied association rule. A passing reference can still be the wrong person, especially when the actual person has no confirmed reference. UMAP coordinates, exact 256-dimensional neighbors, historical context, named-reference diagnostics, and production clusters answer different questions; none substitutes for reviewing the audio.

# Compare projections and exact similarities

After exporting Atlas, generate the comparison page in a fresh ignored directory:

```sh
uv run --no-project --with numpy --with scipy --with 'scikit-learn>=1.8' --with pyarrow --with plotly \
  python experiments/speaker-projector/comparison.py \
  --export tmp/projector-output --site tmp/projector-site \
  --output tmp/projector-comparison
cp tmp/projector-comparison/comparison* tmp/projector-site/
cp tmp/projector-comparison/atlas-index.html tmp/projector-site/projector/index.html
```

Open `/comparison.html` on the same loopback server, or use **Compare Distances** in Atlas. **Distances (MDS)** is the default. **Neighborhoods (UMAP)** retains the original coordinates. **Exact Similarities** shows normalized 256-dimensional cosine scores on a fixed −1 to 1 scale. Select a point, heatmap cell, or sample from the selectors to compare scores and play the corresponding excerpts. Nearest neighbors exclude overlapping same-source excerpts by default.

Metric MDS uses Euclidean chord distance, `sqrt(2 - 2 * cosine)`, with seed 42, four initializations, and at most 600 iterations. Cluster names affect colors and heatmap ordering only. Fidelity uses unique unordered off-diagonal pairs across all samples, including references. Distance-rank correlation is Spearman correlation. Scale-adjusted stress is `sqrt(sum((d - a*q)^2) / sum(d^2))`, where `a = dot(d,q)/dot(q,q)`, `d` is original distance, and `q` is projected distance. It is a custom scale-adjusted residual, not an identity accuracy score.

The generator verifies canonical row identities and each excerpt's exact audio hash, rechecks inputs, and atomically publishes staged artifacts with a receipt. It supports 3–1,000 samples to bound quadratic computation; larger datasets require an explicit sampling study. Plotly is served locally. All-identical embeddings fail clearly instead of producing an arbitrary projection.

# Validate

```sh
uv run --no-project --with numpy --with scipy --with 'scikit-learn>=1.8' python -m unittest discover -s experiments/speaker-projector
```

Synthetic checks cover historical context without identity inheritance, confirmed-reference eligibility, overlapping-audio exclusion, typed-vector compatibility, exact neighbors, complete cluster membership, reference timestamp integrity, capacity trust, and union coverage. Actual production evidence and Atlas rendering are validated separately by the caller.
