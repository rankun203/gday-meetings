---
title: Full-speech global voice clustering comparison
date: 2026-10-25
status: ready-for-listening
scope: latest-twenty-completed-meetings
---

# Findings

Speech detection completed on all 38 audio tracks from the latest 20 completed meetings in the isolated fixture. It scanned 55,723.602 seconds of recording audio and detected 10,827 speech intervals totaling 21,688.594 seconds. Every detected speech sample has an embedding window: 12,079 windows, including 7,404 short intervals extended with recording context. No interval was excluded for duration. All 12,078 unique physical windows produced embeddings, representing all 12,079 observations. The initial ResNet34 run and the later controlled five-model comparison use this same detected-speech inventory. Coverage and grouping counts describe behavior; recognition accuracy awaits listening labels.

The current comparison evaluates five embedding models with full-speech DBSCAN and HDBSCAN against the saved current pipeline. Saved-excerpt DBSCAN variants are excluded from the current review. Global DBSCAN starts with an empty person library and uses every detected interval without a per-person cap. The current transcript view retains the saved pipeline's diarization and person labels. Numerical baseline tables separately describe the preserved replay of saved examples through the current matching policy; these tables do not constitute a fresh end-to-end pipeline run.

For DBSCAN, cosine similarity 0.80 and minimum support 3 are the predeclared reference settings. They have not been established as the best settings. Sensitivity results describe grouping behavior; independent listening labels are required to measure mistaken merges, mistaken splits, and person-recognition accuracy.

The current review loads 18.1 MB for its initial Compare data, reduced from 114.4 MB (84.2%). Transcripts and selected method assignments load on demand. This is a payload measurement; it does not measure browser rendering or cold server startup. Current results and feedback are unchanged.

## References

- [Silero VAD](https://github.com/snakers4/silero-vad) and its [ONNX state and segmentation implementation](https://github.com/snakers4/silero-vad/blob/master/src/silero_vad/utils_vad.py): model protocol and speech-threshold reference. The experiment records the exact cached model hash and uses its own documented segmentation configuration.
- [scikit-learn DBSCAN](https://scikit-learn.org/stable/modules/generated/sklearn.cluster.DBSCAN.html): density neighborhoods, core samples, and noise. The independent-support variant below changes the core criterion; ordinary DBSCAN equivalence tests apply to the ordinary implementation only.
- [Voice recognition library design](../../docs/design/2026-10-24-voice-recognition-library.md): acoustic groups, durable identity decisions, density inflation, conflicts, and recovery.
- Production sources `CommunityVoiceEmbeddingExtractor.swift`, `TypedVoiceEmbedding.swift`, `VoiceMatchingWorker.swift`, `VoiceReviewSelection.swift`, and `SpeakerRecognition.swift`: extraction and the numerical baseline policies.


- [Official ReDimNet2 source and checkpoint table](https://github.com/PalabraAI/redimnet2) define the B6 and B3 variants. Reported VoxCeleb1-O EER measures verification pairs on that benchmark; the B6 0.23% result is not an estimate of meeting-clustering accuracy.
- [Official WeSpeaker pretrained models](https://github.com/wenet-e2e/wespeaker/blob/master/docs/pretrained.md) and [CAM++ large-margin checkpoint](https://huggingface.co/Wespeaker/wespeaker-voxceleb-campplus-LM) identify the selected model. The model card states Apache 2.0 while the pretrained-model documentation lists VoxCeleb models under CC BY 4.0; deployment licensing needs resolution.
- [Official 3D-Speaker inference source](https://github.com/modelscope/3D-Speaker/blob/065629c313eaf1a01c65c640c46d77e61e9607b4/speakerlab/bin/infer_sv.py) defines ERes2NetV2 large architecture and preprocessing.
- [CoreML Tools conversion guidance](https://apple.github.io/coremltools/docs-guides/source/convert-pytorch-workflow.html) and [stable 9.0 dependency bounds](https://github.com/apple/coremltools/blob/9.0/coremltools/_deps/__init__.py) support the isolated export protocol and Torch 2.7 compatibility choice.

- [HDBSCAN parameter guide](https://hdbscan.readthedocs.io/en/latest/parameter_selection.html) explains EOM and leaf selection. [Scikit-learn HDBSCAN documentation](https://scikit-learn.org/stable/modules/generated/sklearn.cluster.HDBSCAN.html) describes the differing self-count convention between implementations.

## Experiment setup

The source fixture independently copied the latest 20 completed meetings, excluding active captures and incomplete finalization. Source hashes and inventories were verified unchanged during capture. Relevant voice examples, representations, decisions, and legacy person references were restricted to those meetings. Pending jobs, resumable work, Undo history, and disposable indexes were omitted; remote providers and automatic processing were disabled. All 38 copied audio hashes match the detector manifest and immutable baseline, with distinct file inodes. The running app and its library are preserved.

The baseline source revision is `daf75bc8113b928f49278ec03aba62d2eb483f38`. The full-speech fixture is an independent copy under ignored `tmp/global-voice-clustering-full-speech/`. The earlier saved-excerpt fixture, outputs, and feedback remain under ignored `tmp/global-voice-clustering/`. Private receipts record exact file hashes, commands, models, and source implementations. Tracked files contain synthetic test content and aggregate measurements.

### Speech detection and embedding coverage

Each audio track is decoded from beginning to end with ffmpeg to mono float32 audio at 16 kHz. Cached Silero ONNX inference uses the CPU provider with one intra-operation and one inter-operation thread. State resets between recordings. Each 512-sample frame receives a speech probability; the final partial frame is zero-padded for inference, while retained intervals stop at the actual decoded sample count.

Segmentation uses onset 0.50, offset 0.35, and 100 ms of low-probability silence to finish a segment. It applies no minimum speech duration or speech padding. Raw probabilities, sample-accurate detected intervals, per-track status, source hashes, and coverage measurements are retained. This establishes complete coverage of detected speech, conditional on this detector; speech missed by VAD remains unmeasured.

Long intervals are divided evenly into disjoint 2–5-second windows, preserving every tail sample. Short intervals are extended symmetrically to two seconds of recording context, clipped at recording edges. Actual speech support and embedding context are separate fields. The 7,404 context-extended windows explicitly retain their padding and overlap status; surrounding audio can include another voice. A recording shorter than two seconds would remain an explicit unsupported observation. None occurred in this fixture. Silero detects speech activity and does not separate simultaneous speakers.

The initial ResNet34 embeddings use the production Community-1 discovery extractor and audio preparation with installed `FBank.mlmodelc` and `Embedding.mlmodelc`. Unique physical windows share extraction work; every observation remains represented. AAC inputs are decoded to float WAV at their original rate and channel count before production resampling. One native 44.1 kHz recording has an end-of-file duration rounding disagreement with the VAD decoder. Its final window uses the same ffmpeg 16 kHz mono decoding as VAD, with separate source/decoded hash receipts and the unchanged Swift embedding model. This preserves the requested window without trimming or dropping speech, while introducing one explicitly different audio-preparation path. Checkpoints retain failures for retry, verify provenance, repair interrupted final journal records, and publish enriched input only when every required embedding succeeds.

### Compared methods

| Method | Evidence and behavior |
| --- | --- |
| Full-speech global DBSCAN | All fresh speech windows in compatible model spaces; cosine similarity 0.80; minimum independent context support 3; cold person library; no automatic person names or per-person sample limit. |
| Current pipeline | Saved diarization and person labels in transcript review. Aggregate numerical replay uses saved examples and the current confirmed-reference selection and matching policy: maximum 12 references per person/model, automatic similarity 0.80, competing-person margin 0.08, and tentative similarity 0.55. |

The DBSCAN variant first collapses identical typed physical windows for density. A core neighborhood then needs three pairwise nonoverlapping embedding contexts, counted separately per physical recording. Earliest-finish interval scheduling finds the maximum nonoverlapping count. Content hashes prevent copied identical audio from appearing independent. Multi-span contexts conservatively use their bounding interval. All windows remain available as core, border, or noise observations. This reduces repeated-context density inflation; it does not prove independent speakers or independent recording conditions.

Core components define acoustic groups. Border observations adjacent to more than one component use stable canonical component ownership. Noise remains unresolved. A group represents acoustic similarity and does not establish a person. User group naming is a reversible listening-review simulation; it neither trains recognition nor changes measured assignments or the People Library.

The methods have different observation domains. Full-speech DBSCAN evaluates newly detected windows, while the baseline numerical replay evaluates saved examples. Group and noise counts therefore describe each method's structure rather than a common-denominator accuracy ranking. The baseline port omits full persistence projection, exact decision scoping, selected-reference dependencies, cross-model agreement, and app proposal selection.

### Metrics, arrivals, and sensitivity

**Grouped observations** belong to a non-noise acoustic group with at least two members. **Noise** lacks a qualifying density-connected cluster. **Core observations** meet the independent-context criterion. **Largest group** counts member observations. **Named observations** include explicit or inferred person identities; cold DBSCAN intentionally has none.

**Changed pairs** counts changes in whether two already present observations share a group. It uses contingency counts so cluster-label renumbering does not create false churn. **Changed identities** counts resolved-person changes on already present evidence. Neither metric measures correctness.

Meeting checkpoints recompute DBSCAN after 5, 10, 15, and 20 meetings. Up to eight sample batches arrive in simulated order by meeting, first speech-support start, and stable sample ID. The baseline is filtered to arrived meetings for meeting checkpoints and remains frozen for sample checkpoints. Its historical recognition state and actual extraction-completion order are unavailable. These are conditional batch recomputations, rather than an incremental online implementation or historical accuracy backtest.

Initial ResNet34 sensitivity evaluates similarities 0.65, 0.70, 0.75, and 0.80 with minimum support 3 and 5. These eight combinations retain the same independent-context density rule. They describe how grouping changes around the predeclared primary policy and do not select a winner.

### Controlled embedding-model comparison

All five models receive identical source-verified 16 kHz mono PCM and the same 12,078 unique physical contexts, expanded to 12,079 observation identifiers. A fresh installed Community-1 WeSpeaker ResNet34 run supplies the controlled baseline. Its frontend follows production active-frame centering and duration masking; the alternatives retain their published native frontends. Equal-length batches avoid extra padding. Inference arrays are stored as float32 and normalized in float64 for cosine comparison. Graphs never combine embedding spaces.

| Model | Checkpoint / training mixture | Embedding dimensions | Execution for full extraction |
| --- | --- | ---: | --- |
| Community-1 WeSpeaker ResNet34 | Installed Community-1 backend | 256 | CoreML frontend CPU; embedding ALL |
| ReDimNet2-B6 | VoxBlink2 + VoxCeleb2, large-margin checkpoint | 192 | Original CPU frontend; PyTorch MPS backbone |
| ReDimNet2-B3 | VoxBlink2 + VoxCeleb2 + CNCeleb2, large-margin checkpoint | 192 | CPU frontend and backbone, four threads |
| ERes2NetV2 large | Official w24s4ep4 Chinese checkpoint, version 1.0.1 | 192 | CPU Kaldi frontend and backbone, four threads |
| WeSpeaker CAM++ | Official VoxCeleb large-margin checkpoint | 512 | CPU Kaldi frontend and backbone, four threads |

Each model sweeps cosine similarities 0.35, 0.45, 0.55, 0.65, 0.75, 0.80, 0.85, and 0.90 with minimum independent support 3 and 5. A 20-million-edge graph limit skips denser thresholds explicitly; remaining settings retain all observations. The 0.80/minimum-3 view is a common reference, not a calibrated or selected optimum. Per-model settings are necessary because similarity scales differ. Meeting and sample arrival replays use the common reference configuration.

The review adds model, algorithm, and setting controls alongside existing transcript playback and judgments. A shared Compare queue evaluates configurations together. Selected settings persist in the URL. Changed predictions retain their earlier judgment with a notice; person corrections remain shared. Unavailable variants block judgments and offer retry. Group names remain scoped to model and exact membership.

Full extraction and clustering are complete. Native deployment measurements use separate numerical agreement checks; failed conversions remain excluded from usable timing estimates.

### HDBSCAN and density controls

The added HDBSCAN comparison fits exact-physical representatives of every model's normalized vectors and restores observation aliases. It uses Euclidean distance on unit vectors, where distance is `sqrt(2 × (1 − cosine))`. That transform preserves neighbor ordering; HDBSCAN stability selection depends on the distance scale, so the result is not claimed to equal a cosine-distance HDBSCAN fit. No embedding dimensionality reduction is applied.

EOM (excess of mass) and leaf cluster selection are compared with minimum cluster sizes 5, 10, and 20 and neighborhood support 3 and 5 including the observation itself. The installed contrib HDBSCAN 0.8.44 implementation excludes self in its `min_samples` parameter; the harness translates these support counts to 2 and 4 and checks this behavior with a synthetic regression. EOM/leaf differences describe alternative stability selections rather than an accuracy ranking.

Exact duplicates count once in every primary fit. Overlapping contexts remain correlated in stock HDBSCAN, whereas the primary DBSCAN variant counts nonoverlapping support within each neighborhood. A secondary matched-density ablation selects deterministic nonoverlapping contexts per physical recording, independently of embeddings or people, then fits stock DBSCAN and HDBSCAN on the same selected observations. Omitted contexts retain their embeddings and playback but are marked as omitted from this fit, separately from algorithmic noise. These controls expose density-policy differences instead of attributing every difference to the clustering algorithm.

### Reusable listening judgments

A shared pair judgment answers whether two excerpts contain the same person. Its truth applies across every model and configuration. Optional person names create further pair comparisons wherever both excerpts have reviewed names. Existing transcript person corrections are reused only where they completely cover a sample's detected speech support and agree. Model-specific judgments remain available in the transcript reader.

The completed queue contains 1,600 prioritized disagreements and 400 seeded random physical-context controls. Group representatives and nearby embeddings propose candidates; repeated or overlapping physical contexts are excluded as pairs. Prioritized excerpts contain at least one second of speech, while random controls retain short speech. Predictions stay hidden until an answer or explicit reveal. The queue is bounded and does not enumerate every possible pair. It is a pool for short review sessions, not a requirement to label all 2,000 pairs. Per-pair predictions stay collapsed after answering unless explicitly opened; their expanded table is scrollable. Both disclosure and paused playback state persist in the URL.

A **wrong merge** predicts one group for a pair judged different. An **unnecessary split** predicts separate non-noise groups for a pair judged the same. **Unresolved** means one or both predictions abstain; **omitted** means a context was excluded from a matched fit. Unsure, mixed-audio, and conflicting truth are excluded from correctness counts. The scoreboard reports these counts and denominators, including direct and name-derived judgments. Prioritized-pair results are selected for disagreement and cannot estimate population accuracy. Random controls sample physical audio pairs, not people uniformly; sufficient same-person and different-person evidence is still required for useful error-rate estimates.

### Controlled clustering results

The completed comparison contains 224 fitted configurations plus the saved app result: 135 primary configurations (including the saved app result) and 90 matched-density controls. Three lowest-threshold DBSCAN sweeps reached the predeclared graph-size guard; similarity 0.35 is omitted for B6, B3, and ERes, affecting six requested settings. All other requested settings completed. Every primary fit retains all 12,079 observations.

The table uses DBSCAN similarity 0.80/support 3 and HDBSCAN minimum cluster size 5/support 3. These are reference settings, not selected winners. Grouped and noise counts include the one observation alias.

| Model | Algorithm | Groups | Grouped | Noise | Largest group |
| --- | --- | ---: | ---: | ---: | ---: |
| ResNet34 | DBSCAN | 31 | 2,048 | 10,031 | 386 |
| ResNet34 | HDBSCAN EOM | 51 | 6,994 | 5,085 | 1,656 |
| ResNet34 | HDBSCAN leaf | 73 | 2,714 | 9,365 | 630 |
| ReDimNet2-B6 | DBSCAN | 45 | 7,256 | 4,823 | 2,113 |
| ReDimNet2-B6 | HDBSCAN EOM | 50 | 8,395 | 3,684 | 2,405 |
| ReDimNet2-B6 | HDBSCAN leaf | 78 | 2,441 | 9,638 | 267 |
| ReDimNet2-B3 | DBSCAN | 51 | 6,895 | 5,184 | 2,575 |
| ReDimNet2-B3 | HDBSCAN EOM | 3 | 12,078 | 1 | 11,559 |
| ReDimNet2-B3 | HDBSCAN leaf | 114 | 2,032 | 10,047 | 221 |
| ERes2NetV2 large | DBSCAN | 98 | 7,311 | 4,768 | 2,203 |
| ERes2NetV2 large | HDBSCAN EOM | 73 | 9,205 | 2,874 | 2,719 |
| ERes2NetV2 large | HDBSCAN leaf | 154 | 2,689 | 9,390 | 161 |
| CAM++ | DBSCAN | 32 | 2,477 | 9,602 | 728 |
| CAM++ | HDBSCAN EOM | 54 | 7,011 | 5,068 | 2,135 |
| CAM++ | HDBSCAN leaf | 78 | 1,928 | 10,151 | 172 |

EOM and leaf produce substantially different partitions. B3 EOM groups 12,078 observations into three groups, with 11,559 in the largest; leaf instead groups 2,032 observations into 114 groups. This exposes an important listening question about merges and splits, rather than establishing which partition is correct. Similarity calibration also differs across embedding models.

The matched-density controls fit 8,390 nonoverlapping physical contexts (8,391 observations) and omit 3,688 overlapping contexts from fitting. Omissions remain separately inspectable and playable. The full configuration matrices, membership strengths, persistence diagnostics, and density controls are available in the review.

#### Arrival stability

Each cell below reports cumulative changed co-membership pairs for meeting checkpoints / sample checkpoints. These are repeated change events among existing evidence, not incorrect decisions or distinct affected pairs. Cluster numbers are ignored. DBSCAN replay counts observation IDs, including the one duplicate alias; HDBSCAN counts physical context IDs. The counts therefore have a slightly different unit and must not be treated as an exactly matched stability ranking. A shared physical-context projector is required before such a ranking.

| Model | DBSCAN | HDBSCAN EOM | HDBSCAN leaf |
| --- | ---: | ---: | ---: |
| ResNet34 | 2,720 / 8,454 | 104,227 / 808,706 | 614,949 / 782,099 |
| ReDimNet2-B6 | 24,104 / 73,668 | 532,262 / 1,152,991 | 110,546 / 678,942 |
| ReDimNet2-B3 | 331,137 / 407,093 | 0 / 0 | 49,020 / 335,466 |
| ERes2NetV2 large | 29,208 / 92,153 | 63,173 / 1,317,263 | 85,172 / 181,610 |
| CAM++ | 6,593 / 18,751 | 124,811 / 594,075 | 153,761 / 900,356 |

Final HDBSCAN checkpoints reuse the corresponding full-batch assignment; intermediate checkpoints refit arrived evidence. Refit churn is conditional on this arrival protocol. The current baseline remains a saved reference and does not supply an equivalent historical reprocessing experiment.

### Initial ResNet34 full-speech results

All 12,079 windows have finite, unit-normalized 256-dimensional embeddings from one compatible model. One duplicate embedding context shares extraction work, leaving 12,078 unique physical jobs. Nineteen meetings contain detected speech; the twentieth has no detected speech and remains available for full-recording review. Speech support matches the manifest for every embedded observation. All required embeddings succeeded after the one-window end-of-file fallback. Summed per-window extraction work was 844.839 seconds, with median 0.061975 seconds; measured subprocess wall time includes decoding, compilation, checkpoint handling, and retries separately below.

| Method | Observations | Multi-observation groups | Grouped observations | Noise | Core observations | Largest group | Named observations |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Full-speech DBSCAN, independent context support | 12,079 | 27 | 1,978 | 10,101 | 1,650 | 400 | 0 |
| Current saved-example numerical replay | 3,229 | 101 | 3,117 | — | — | 338 | 5 |

The baseline's five named observations include two confirmations and three inferred aliases, with zero newly identified physical ranges. The cold DBSCAN result intentionally contains no names. Different observation domains and group scopes prevent interpreting the table as a head-to-head accuracy score.

| Similarity | Minimum support | Multi-observation groups | Grouped observations | Noise | Largest group |
| --- | ---: | ---: | ---: | ---: | ---: |
| 0.65 | 3 | 44 | 8,112 | 3,967 | 5,964 |
| 0.65 | 5 | 35 | 7,945 | 4,134 | 5,014 |
| 0.70 | 3 | 49 | 6,132 | 5,947 | 1,702 |
| 0.70 | 5 | 33 | 5,930 | 6,149 | 1,678 |
| 0.75 | 3 | 47 | 3,914 | 8,165 | 1,008 |
| 0.75 | 5 | 28 | 3,713 | 8,366 | 982 |
| 0.80 | 3 | 27 | 1,978 | 10,101 | 400 |
| 0.80 | 5 | 12 | 1,870 | 10,209 | 394 |

Lower thresholds sharply increase grouped coverage and the largest component. Listening labels must establish whether those changes merge distinct people. More grouped evidence alone does not justify a setting change.

| Arrived meetings | Observations | Multi-observation groups | Grouped observations | Noise | Changed existing pairs since checkpoint |
| --- | ---: | ---: | ---: | ---: | ---: |
| 5 | 2,124 | 10 | 635 | 1,489 | 0 |
| 10 | 6,174 | 16 | 1,269 | 4,905 | 245 |
| 15 | 10,569 | 23 | 1,849 | 8,720 | 1,695 |
| 20 | 12,079 | 27 | 1,978 | 10,101 | 2,447 |

The meeting replay totals 4,387 repeated pair-change events. Eight sample batches, with target size 1,510, total 9,473. These sums count events across checkpoints, rather than distinct affected pairs. Both final recomputations match the full-batch grouping. Person identities remain unchanged: DBSCAN has none, and the baseline is preserved. The frozen baseline's zero churn is a property of this protocol and cannot establish greater historical stability.

The sparse graph retains 1,062,050 directed similarity entries, including self-neighbors, at the minimum sensitivity similarity 0.65. It uses 256-row blocks and a 20-million-edge limit. The initial numerical evaluation took 11.698 seconds inside the comparison process; measured stage costs, including a metadata-correction rerun, appear below.

### Controlled extraction resources

All five fresh extraction runs completed 12,078 unique contexts and 12,079 observation rows. The contexts total 8.4915 hours, including added context around short speech. Runs were sequential on the same M1 Max host; implementations and execution backends differ as specified above.

| Model | Wall seconds | CPU seconds | Process peak MiB | Sampled tree peak MiB |
| --- | ---: | ---: | ---: | ---: |
| Community-1 ResNet34 | 167.375 | 77.946 | 1983.8 | 2009.1 |
| ReDimNet2-B6 | 3469.710 | 3249.202 | 8081.1 | 8059.7 |
| ReDimNet2-B3 | 836.450 | 2177.813 | 4490.8 | 4501.2 |
| ERes2NetV2 large | 1399.425 | 5551.499 | 9686.4 | 9683.3 |
| WeSpeaker CAM++ | 211.457 | 487.687 | 5935.3 | 5945.7 |

The B6 MPS run incurred repeated cold-input-shape costs; the remaining unstarted alternative-model runs used four CPU threads. This comparison measures the chosen pipelines rather than equal-backend model speed. Two initial ResNet launch attempts failed before inference because NumPy was missing; their costs remain separate receipts. Process peaks include Python/framework allocations and exclude separately running accelerator services. Native CoreML checks and projections are reported separately.


| Measured stage | Wall seconds | CPU seconds | Process peak MiB | Sampled tree peak MiB |
| --- | ---: | ---: | ---: | ---: |
| Shared audio preparation | 113.026 | 190.506 | 823.7 | 604.7 |
| Five-model DBSCAN sweeps and arrivals | 122.335 | 116.392 | 2372.9 | 2389.7 |
| ResNet34 HDBSCAN and controls | 89.372 | 62.806 | 4732.5 | 4768.1 |
| B6 HDBSCAN and controls | 54.344 | 55.087 | 4942.7 | 4978.2 |
| B3 HDBSCAN and controls | 54.129 | 54.713 | 4451.5 | 4487.1 |
| ERes HDBSCAN and controls | 53.454 | 54.214 | 4451.1 | 4486.7 |
| CAM++ HDBSCAN and controls | 80.359 | 82.468 | 4649.9 | 4683.3 |
| Shared pair-review construction | 61.345 | 61.370 | 3255.4 | 3242.6 |

HDBSCAN stages include all primary and matched settings, arrival replays, and artifact writes. Exact minimum-spanning-tree calculations are cached across settings that share their inputs; per-setting warm fit time must not be interpreted as independent cold-run cost. The pair builder produced 2,000 candidate comparisons across 225 configurations. This is an optional review pool, not a labeling completion target.

### Native CoreML components and deployment estimates

The original four alternative-model pipelines passed CPU/MPS agreement checks on private audio. Native CoreML feature backbones were then checked on nine private speech windows: three each at 2, 3, and 5 seconds. B3, B6, and ERes passed. Their timings use native `ALL` compute selection; this does not identify which accelerator executed each operation.

| Model | Precision | Private minimum cosine | One fixed package MB | Isolated process peak MB | Warm 3-second backbone ms | Projected warm serial seconds for all contexts |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| ReDimNet2-B6 | FLOAT16 | 0.999994 | 25.43 | 204.3 | 60.86 | 720.8 |
| ReDimNet2-B3 | FLOAT16 | 0.999984 | 9.52 | 168.8 | 38.04 | 454.7 |
| ERes2NetV2 large | FLOAT16 | 0.999983 | 107.27 | 419.0 | 34.20 | 281.8 |
| CAM++ | FLOAT32 | 0.119838 | 29.53 | Unavailable | Unavailable | Unavailable |

CAM++ failed FP16 private parity (minimum cosine 0.903862), FP32 private parity (0.119838), and an FP32 CPU-only diagnostic (0.120996). Its package size describes an artifact that failed numerical validation, not a usable deployment model. Its latency, memory recommendation, and throughput projection are withheld. The original PyTorch CAM++ embeddings and clustering results remain valid. A potential follow-up is the conversion of ceil-mode segment average pooling; this is an unverified hypothesis, not an identified cause.

The installed ResNet34 waveform pipeline measured 167.375 seconds and 2,080.1 MB process peak for the full batched extraction, with 15.29 MB of compiled model files. That full-harness memory figure and batched wall time are not comparable to the alternatives’ isolated single-window runtime memory and warm serial projections.

MB and GB use decimal bytes; the extraction tables above use binary MiB. Each isolated memory measurement uses a fresh Torch-free Python/CoreML process and one private 3-second package, including Python/CoreML overhead. It excludes waveform preprocessing, device allocations, and separate CoreML/ANE services. During earlier compilation checks, the separate ANE compiler service grew from roughly 0.79 to 1.59 GB; that system observation is not attributed to any single model or included in the table.

The projections interpolate native warm backbone medians at 2/3/5 seconds over the actual 12,078-context duration histogram, then add separately measured four-thread CPU frontend and L2-normalization work. They assume serial processing. They exclude decoding, I/O, loading, cold compilation, new-shape specialization, batching, and scheduling overlap. These are hybrid prototype estimates, not native-app measurements or first-library throughput predictions.

Three separate fixed-shape packages duplicate weights: totals are 76.30 MB for B6, 28.55 MB for B3, and 321.82 MB for ERes. Parameter-only shared-weight estimates are respectively 24.92, 9.02, and 107.03 MB. A production flexible-shape package covering all observed durations has not been built. The full measured pipeline must be tested again after frontend integration and package design.

All 63 measured stage receipts, including failed conversions and interrupted or failed preparation attempts, remain attached to the review. Conversion memory is separate from runtime memory. Torch 2.7 and NumPy 1.26.4 are retained for compatibility with stable CoreML Tools 9. B6 conversion emitted an FP16 constant-cast overflow warning; native numerical checks passed on the tested cases, and the warning remains recorded.

### Initial full-speech resource measurements

Resource receipts remain under ignored `tmp/full-speech-resources/` and are attached to the final result with hashes. The measured host is an Apple M1 Max MacBookPro18,4 with 10 logical CPUs and 64 GiB RAM. Stages are measured as subprocess trees; inference uses the optimized standalone Swift extractor rather than a release app bundle.

| Attempt | Status | Wall seconds | CPU seconds | Process peak MiB | Sampled tree peak MiB | Net directory growth MiB |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Initial independent copy | Failed before launch | 0.002 | Unavailable | Unavailable | Unavailable | 0 |
| Independent copy retry | Completed | 0.811 | 0.640 | 2.344 | 3.344 | 265.092 |
| Speech detection | Completed | 205.673 | 372.620 | 227.641 | 286.031 | 26.115 |
| First embedding attempt | Interrupted | 88.122 | 89.642 | 106.859 | 144.109 | 863.089 |
| Embedding retry | Process completed; one excerpt failed | 906.208 | 818.887 | 1,396.156 | 1,558.469 | 279.172 |
| End-of-file embedding recovery | Completed | 17.376 | 17.536 | 576.031 | 494.500 | 146.151 |
| Recording mix preparation | Completed, 20 recordings | 95.237 | 188.331 | 131.953 | 174.141 | 889.273 |
| Initial comparison | Completed; metadata corrected later | 16.506 | 16.355 | 1,228.562 | 1,260.344 | 277.807 |
| Final comparison | Completed | 16.943 | 16.717 | 1,231.672 | 1,263.531 | 0.000 |

The initial copy measurement was blocked by a sandboxed system-information query before copying; the retry completed. The first embedding attempt was interrupted and resumed from its checkpoint. The retry process completed, but one excerpt failed its decoded-audio boundary check. Its separately measured decoder fallback recovered the final job. The corrected result reports zero failed windows. An initial comparison inherited a negative failure counter from mixing unique-job and observation counts; the corrected counter uses observation counts, has a duplicate-window regression, and was republished through a separately measured comparison rerun. Its work and resource cost remain in the receipts. Resource totals must include failed and interrupted attempts explicitly.

Sampled tree RSS sums resident memory at 0.2-second intervals, can double-count shared pages, and can miss brief children. Process high-water RSS is a separate platform measurement. Stage wall and CPU times can overlap; memory peaks must not be summed. Net apparent directory growth excludes peak disk use and allocated APFS blocks. When stages overlap, growth can include other writers in the same experiment directory and cannot be attributed solely to one process. The directory held approximately 2,746.699 MiB after the final comparison. GPU, Neural Engine utilization and memory, energy, unrelated system activity, and the earlier baseline's extraction resource cost are unavailable. These measurements do not establish full-library scalability.

### Architecture implications

The app already treats embedding compatibility as a complete contract: model, revision, preprocessing compatibility version, dimension, and normalization. `TypedVoiceEmbedding.swift` identifies the installed Community-1 model as WeSpeaker ResNet34 with 256 dimensions. `VoiceLibraryStore.swift` can retain separate compatible representation types for one piece of evidence; matching still requires equal types. Alternative vectors should therefore remain separate model spaces rather than be averaged or compared directly.

Local diarization has a stronger dependency: the installed FluidAudio PLDA transform accepts 256-dimensional embeddings and produces a 128-dimensional representation. ReDimNet2/ERes vectors have 192 dimensions and CAM++ has 512, so these are not direct replacements for that trained diarization transform. An alternative global grouping model can be evaluated while local activity and boundaries remain evidence. A production change still needs an authoritative identity resolver, stable person identities, explicit correction handling, and a maintained frontend/export contract. This experiment changes none of those app components.

### Archived saved-excerpt ablation

The earlier study held saved speech boundaries fixed. It retained 3,229 saved examples representing 3,122 unique physical ranges across 19 vector-bearing meetings; the twentieth meeting had no saved examples. All 3,122 unique excerpts produced finite, unit-normalized 256-dimensional embeddings. Only 105 cached vectors existed initially. Their regenerated counterparts had median cosine agreement 0.999918 and minimum 0.999680. Extraction work totaled 377.5 seconds, excluding compilation, retries, and decoding; the six-method numerical comparison took 36.2 seconds. These timings were collected under a different protocol and are not directly comparable with the full-speech resource receipts.

| Archived method | Multi-sample groups | Grouped records | Noise | Named records | Newly identified physical ranges |
| --- | ---: | ---: | ---: | ---: | ---: |
| Saved local labels + current scoring | 101 | 3,117 | — | 5 | 0 |
| Saved local labels + unlimited references | 101 | 3,117 | — | 5 | 0 |
| Complete-link kernel + current scoring | 62 | 126 | — | 5 | 0 |
| Raw-record DBSCAN | 41 | 1,396 | 1,833 | 4 | 0 |
| Exact-range-density DBSCAN | 29 | 1,360 | 1,869 | 2 | 0 |
| Raw-record DBSCAN without names | 41 | 1,396 | 1,833 | 0 | 0 |

The central archived finding is duplicate-only propagation. Raw DBSCAN inferred two identities in a three-record group containing one physical excerpt: a confirmed record and two aliases. Counting physical ranges once removed both inferences. Current matching's three inferences likewise concerned aliases of its two confirmed ranges. Meeting-label density still permitted duplicate propagation because the aliases carried different local speaker IDs. No archived default method recognized previously unconfirmed physical audio. This motivates explicit physical-support handling in the full-speech experiment.

The two confirmed people provide limited competition and do not exercise reference-cap saturation. Across the archived 45-setting grid, raw DBSCAN grouped 96–2,507 records. Chronological meeting, sample-batch, and reverse-meeting replays produced respectively 4,406, 6,685, and 2,662 cumulative pair-change events; exact-range density produced 4,414, 6,696, and 2,672. Final batch and reversed-iteration results agreed on this dataset. These archived results establish measured behavior, rather than general order independence or a quality winner. The six saved-excerpt variants remain archived data and are absent from the model comparison review.

## Validation and limitations

The source prepared for commit passes 169 Python tests and 106 Node state tests, including nine temporary-server tests. JavaScript syntax and whitespace checks also pass. Coverage includes speech-window completeness, model binding, resumable extraction, density controls, HDBSCAN self-count semantics, variant integrity, reusable pair truth, feedback recovery, and URL restoration. Independent reviews addressed architecture, lifecycle, data projection, and provenance; an aggregate audit matched every controlled reference-table and arrival-count value.

Real-data browser checks on <http://127.0.0.1:8771> verified the 225-configuration Compare page, one-action exclusive clip playback, matching transcript navigation, model/algorithm/EOM/leaf controls, global-group display, and paused Back restoration. Synthetic browser checks covered names, exclusions, filtered queues, recovery behavior, and the 140-setting disclosure layout. Earlier review servers are retired; the current comparison uses port 8771. Two saved transcript corrections were migrated without modifying their source file; no real pair judgments were added during verification.

Automatic approval review blocked manual Save Feedback and Dismiss Notice in the isolated synthetic browser test, respectively treating them as an unauthorized persistent write and potential recovery-draft loss. Neither was retried. Automated temporary-server persistence/reload tests passed; those two browser actions remain validation limits. Initial full-speech validation had passed 82 Python and 26 Node tests with the earlier two-method review; those historical counts do not describe the expanded comparison.

Existing regressions cover snapshot consistency, extraction checkpoints, matching mechanics, transcript projection, feedback recovery, range playback, and exclusive playback. Ordinary DBSCAN matched scikit-learn on 15 randomized synthetic datasets in the archived study. That check does not validate the independent-support criterion by equivalence to ordinary DBSCAN.

The transcript review preserves canonical text and constituent identities; 8,800 fragments form 4,789 passages across 19 meetings. The remaining meeting supports recording playback without a saved transcript. Projection uses actual detected speech support for DBSCAN and saved labels for the current pipeline, with partial and conflicting coverage explicit. All 4,789 passages have available copied audio. Filtering coverage to full-speech method observation IDs gives 298 fully covered passages, 4,103 partially covered passages, and 388 with no overlapping full-speech evidence. Full-speech support covers 21,241.400 of 28,312.165 passage-timeline seconds. Coverage includes both clustered and noise evidence; it does not imply a resolved identity or correct recognition. These method-specific counts exclude the saved examples present in the combined review payload. Transcript display is a listening aid, and transcript text never selects speech or embedding windows.

Listening review is unblinded and uses partial identity evidence. Independent held-out identity labels and separated enrollment/evaluation meetings are needed for accuracy claims. VAD misses, mixed context, simultaneous voices, and real user corrections need assessment. The app's hidden-source preferences and transient drafts are outside the replay. DBSCAN uses a sparse blockwise neighborhood graph, but graph growth and repeated batch recomputation remain scalability limits. The measured HDBSCAN generic backend uses quadratic dense distance storage under a planning guard; the 20-meeting results do not establish suitability for an entire growing library. Exact Prim is an available slower alternative. Production integration needs a separately measured scalability policy.

The earlier extraction emitted CoreML cache and CAF-format runtime warnings and completed with fallback behavior. Full-speech extraction completed with the ignored noninterleaved CAF-setting warning. The CoreML cache warning did not appear in the final full-speech diagnostics. No Swift app code is changed by this experiment; standalone compilation does not establish release-app or end-to-end pipeline validation.
