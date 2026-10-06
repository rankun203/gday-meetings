---
title: Core ML embedding optimization results
date: 2026-10-06
status: evaluated-with-limits
scope: embedding-latency-experiment
---

# Findings

**Separate the query and document shapes.** Both models' 128-token conservative selective-FP16 query encoders preserve all 102 first results and every top-five result set against their original FP32, 512-token document indexes. Queries use at most 29 tokens for 97M and 28 for 311M in this development set. Document windows reach 238 and 225 tokens respectively, so a short query path must not impose a short document limit. Keep a 512-token fallback for longer queries; never truncate a query to obtain the measured speedup.

**Selective FP16 is the strongest precision candidate; aggressive palettes are not ready.** Conservative selective FP16 approximately halves package size and retains numerical parity on the evaluated corpus. The tested 97M 4-bit/6-bit and 311M 6-bit palettes reduce labeled retrieval accuracy after rebuilding the index. The 97M 8-bit palette is closer, but still changes ranking and loses one top-five evidence hit. These are specific post-training conversions, not evidence that every palettization method fails.

**Model loading remains a separate cost.** A fast warmed encoder does not guarantee an immediate first search. Load the short-query encoder and index in the background when the preference is enabled. Load the document encoder for indexing or long-query fallback. The deployed multifunction package shares weights between the short-query and document functions. The app loads and warms the query function first, then loads the document function lazily for indexing or long queries.

The final latency matrix was repeated after laptop wake. Following authorization, conservative selective FP16 was packaged with shared weights, published alongside the preserved FP32 artifacts, and selected by the app registry. Real-library validation completed on 366 meetings; packed vector storage reduced complete search latency by about 10.5×, independently of the embedding improvement.

# References

Apple's [typed execution guide](https://apple.github.io/coremltools/docs-guides/source/typed-execution.html) distinguishes stored precision from runtime execution. [Selective precision conversion](https://github.com/apple/coremltools/blob/main/coremltools/converters/_converters_entry.py) allows operations to remain FP32. Apple's [palettization API](https://apple.github.io/coremltools/docs-guides/source/opt-palettization-api.html) supports post-training K-means palettes; [optimization guidance](https://apple.github.io/coremltools/docs-guides/source/opt-overview.html) recommends measuring the target hardware because decompression differs by device. Compute-plan device preferences are predictions, not runtime traces.

# Experiment Setup

Hardware is an Apple M1 Max with 64 GiB unified memory, macOS 26.6.2 (25G83). Conversion uses the locked search-worker environment: coremltools 9.0, PyTorch 2.7.0, Transformers 4.57.3 and NumPy 1.26.4. Native prediction uses an optimized Swift executable and Core ML. Full Xcode is selected per command for `coremlcompiler`, without changing system settings.

Use the exact IBM revisions and tokenizers from the published Core ML conversion, with CLS pooling, L2 normalization, no prefixes, and batch one. Granite 97M is pinned to `835ad14087e140460703cf0fae09f97d469d65c2` (384 dimensions); 311M to `44399559930365213510b1ee2eb15ded83374f0e` (768 dimensions). Inputs are int32 token IDs and attention masks; output embeddings remain float32. Output dtype alone does not describe internal compute precision.

**FP32** keeps converted computation in float32. **Selective FP16** preserves select, add, softmax, layer normalization, L2 reduction, and division in FP32 while reducing other computation and weights. This conservative policy isolates the attention-mask overflow seen with automatic FP16. **Bounded-mask FP16** clamps both ModernBERT attention masks to a minimum of −10,000, preserves select/clip and output normalization in FP32, and permits attention additions, softmax and layer normalization to use FP16. It is an experimental override of the pinned model implementation, not a general-purpose conversion rule.

**Palettization** replaces weight values with indices into a small lookup table. The evaluated palettes use post-training scalar K-means, 4/6/8 bits, a 2,048-element weight threshold, two clustering workers, and the selective-FP16 package as input. Large FP16 tensors use coremltools' weighted `kmeans1d` implementation. There is no calibration, training, per-layer sensitivity tuning, or groupwise palette tuning. An exploratory FP32-source palette conversion required scikit-learn and was stopped; it contributes no results.

The input-length ablation compares 128-token query and 512-token query/document shapes without shortening eligible text. Retrieval evaluation reuses the local audio-retrieval experiment's 102 bilingual queries and 1,677 transcript windows. All inputs fit 512 tokens and all queries fit 128. The corpus contains empty passages, which remain candidates for consistency. This is the same development set, with nonexhaustive evidence labels, not a new held-out benchmark. Speaker bonuses are disabled to isolate embedding effects.

Native Swift timings separate model load, first prediction, and 50 warm predictions. Warm p50 and p95 use sorted samples at `floor((n−1) × p)`. The primary latency comparison uses the same six short synthetic bilingual inputs at both shapes, three fresh processes per variant, and automatic device selection (`.all`). A separate seven-probe device-policy comparison includes a long input. Existing execution-plan and filesystem caches are not deleted; fresh-process load is not an uncached first-install claim. Reported package size is uncompressed `.mlpackage` bytes, excluding compiled artifacts and tokenizers. It is not download size or resident memory.

Accuracy runs may overlap conversion or UI build work; their incidental latency values are excluded. The final latency matrix runs after laptop wake with no conversion, indexing evaluation or release build in parallel. Device-policy measurements preceded sleep. Raw vectors, input text, model artifacts and timing receipts remain ignored and local.

**Embedding agreement** is cosine similarity between paired normalized baseline/candidate vectors; 0.9999 is the strict parity target. **Top-1 agreement** counts identical first-result passage IDs. **Top-five overlap** averages the shared fraction of each five-result set, ignoring order within that set. **Evidence hit @k** counts queries with a labeled passage among the first k results; **evidence recall @5** averages the recovered fraction of each query's labeled passages. **MRR** averages reciprocal rank of the first labeled result. Labels are nonexhaustive, so these metrics do not judge every useful alternative passage.

**Mixed index** compares candidate query embeddings with the baseline's FP32 document embeddings. **Reindexed** replaces both query and document embeddings. The main retrieval matrix uses matching 512-token candidates or 128-token queries against FP32/512 documents; the separate paired matrix uses 128-token candidates against rebuilt selective-FP16/512 documents. Numerical compatibility on this set does not waive the app's index-version and rebuild rules when shipping a new model.

# Results

## Latency and package size

Medians across three fresh processes; each warm run contains 50 predictions. All final runs reported nominal thermal state. Load and first prediction are cache-dependent and listed separately. Sizes use decimal MB.

| Model / method | Tokens | Package MB | Load ms | First prediction ms | Warm p50 ms | Warm p95 ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 311m-bounded | 128 | 623.7 | 203 | 122 | 8.89 | 9.20 |
| 311m-bounded | 512 | 624.2 | 254 | 152 | 23.16 | 23.48 |
| 311m-fp32 | 128 | 1247.1 | 304 | 129 | 10.00 | 10.30 |
| 311m-fp32 | 512 | 1247.7 | 347 | 154 | 25.00 | 25.43 |
| 311m-palette6 | 512 | 234.6 | 196 | 2201 | 24.56 | 24.94 |
| 311m-selective | 128 | 623.9 | 216 | 127 | 9.50 | 9.74 |
| 311m-selective | 512 | 624.3 | 246 | 142 | 24.48 | 24.94 |
| 97m-bounded | 128 | 195.1 | 114 | 41 | 4.09 | 4.73 |
| 97m-bounded | 512 | 195.5 | 155 | 88 | 9.35 | 10.11 |
| 97m-fp32 | 128 | 390.0 | 156 | 79 | 7.15 | 8.48 |
| 97m-fp32 | 512 | 390.5 | 177 | 93 | 8.44 | 8.70 |
| 97m-palette4 | 512 | 49.3 | 140 | 104 | 11.28 | 11.54 |
| 97m-palette6 | 512 | 73.7 | 144 | 724 | 10.16 | 10.34 |
| 97m-palette8 | 512 | 98.1 | 172 | 98 | 11.44 | 11.73 |
| 97m-selective | 128 | 195.2 | 122 | 84 | 6.30 | 7.79 |
| 97m-selective | 512 | 195.5 | 156 | 92 | 10.13 | 10.37 |

The lowest measured latency is bounded-mask/128, but it is not numerically identical to the baseline. Conservative selective/128 is the lower-risk candidate: about 25% lower warm latency for 97M and 62% lower for 311M versus FP32/512. Package size is roughly halved. The shorter shape itself does not halve weights, and 128-token FP32 also improves latency. Palettes do not provide a consistent warm-speed gain, and 6-bit first prediction is particularly expensive.

Earlier first-observed FP32 loads were 1,522 ms for 97M and 4,789 ms for 311M, versus 177/347 ms in the final cache-warmed matrix. Those observations are not controlled cold-install tests. They show why background loading and a first prediction matter more to first-search responsiveness than a few milliseconds of warmed inference.

## Retrieval preservation

Each row is compared with its own model size’s FP32/512 baseline. At 512 tokens, both query and document embeddings are replaced. At 128 tokens, the document index remains FP32/512. The aggregate receipts also retain mixed-index, recall and MRR results.

| Variant | Minimum vector cosine | Top-1 agreement | Top-five overlap | Evidence hit @1 | Evidence hit @5 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 97m FP32/512 baseline | 1.000000 | 100.00% | 100.00% | 56.86% | 75.49% |
| 97m-bounded-128 | 0.999959 | 100.00% | 99.61% | 56.86% | 75.49% |
| 97m-bounded-512 | 0.999991 | 100.00% | 99.80% | 56.86% | 75.49% |
| 97m-fp32-128 | 1.000000 | 100.00% | 100.00% | 56.86% | 75.49% |
| 97m-palette4-512 | 0.773107 | 55.88% | 47.06% | 49.02% | 71.57% |
| 97m-palette6-512 | 0.953714 | 82.35% | 70.39% | 52.94% | 72.55% |
| 97m-palette8-512 | 0.995865 | 99.02% | 97.06% | 56.86% | 74.51% |
| 97m-selective-128 | 1.000000 | 100.00% | 100.00% | 56.86% | 75.49% |
| 97m-selective-512 | 0.999995 | 100.00% | 100.00% | 56.86% | 75.49% |
| 311m FP32/512 baseline | 1.000000 | 100.00% | 100.00% | 63.73% | 81.37% |
| 311m-bounded-128 | 0.999999 | 100.00% | 99.80% | 63.73% | 81.37% |
| 311m-bounded-512 | 0.999985 | 100.00% | 100.00% | 63.73% | 81.37% |
| 311m-fp32-128 | 1.000000 | 100.00% | 100.00% | 63.73% | 81.37% |
| 311m-palette6-512 | 0.130463 | 78.43% | 69.41% | 58.82% | 77.45% |
| 311m-selective-128 | 0.999998 | 100.00% | 100.00% | 63.73% | 81.37% |
| 311m-selective-512 | 0.999993 | 100.00% | 99.80% | 63.73% | 81.37% |

All evaluated vectors are finite. The 0.9999 cosine target is met by every FP32, selective and bounded-mask candidate on these inputs; palettes miss it. Passing this target does not guarantee identical boundary rankings.

### Short-query encoder with a rebuilt selective-FP16 document index

These pairings directly test a deployment with 128-token queries and 512-token documents.

| Query encoder | Document encoder | Top-1 agreement | Top-five overlap | Evidence hit @1 | Evidence hit @5 |
| --- | --- | ---: | ---: | ---: | ---: |
| 311m-bounded/128 | 311m-selective/512 | 100.00% | 99.80% | 63.73% | 81.37% |
| 311m-selective/128 | 311m-selective/512 | 100.00% | 99.80% | 63.73% | 81.37% |
| 97m-bounded/128 | 97m-selective/512 | 100.00% | 99.61% | 56.86% | 74.51% |
| 97m-selective/128 | 97m-selective/512 | 100.00% | 100.00% | 56.86% | 75.49% |

The faster 97M bounded-mask query path loses one top-five evidence hit when paired with a rebuilt selective document index. Retain conservative selective precision as the default candidate until broader quality validation justifies this tradeoff.

## Device policy and planned placement

CPU+ANE means GPU is disallowed and CPU fallback is permitted. It does not mean successful ANE execution. These earlier three-run medians use nominal/fair thermal states; the 512-token variants also include a seventh long synthetic input, so use them for the device-policy comparison rather than pooling them with the final latency matrix.

| Variant | Automatic warm p50 ms | CPU+GPU warm p50 ms | CPU+ANE warm p50 ms |
| --- | ---: | ---: | ---: |
| 97m-fp32-512 | 8.84 | 8.67 | 52.99 |
| 97m-selective-512 | 10.30 | 9.54 | 114.61 |
| 97m-selective-128 | 6.02 | 6.42 | 13.71 |
| 311m-fp32-512 | 26.12 | 25.64 | 152.16 |
| 311m-selective-512 | 24.83 | 24.95 | 328.03 |
| 311m-selective-128 | 9.67 | 9.57 | 27.45 |

Forcing CPU+ANE is slower for every tested conservative variant. In the 128-token `.all` plans, conservative 97M/311M assign all operations with estimated cost to GPU. Bounded-mask 97M assigns approximately 37.9% of estimated cost to ANE and 62.1% to GPU; bounded-mask 311M still assigns its estimated cost to GPU. Constant/control operations without device-cost estimates are excluded from those proportions. These are compiler preferences, not measured runtime utilization.

## Deployment

The published variant uses conservative selective-FP16 weights with `query128` as the default function and `passage512` for documents and longer queries. Apple's [multifunction packaging](https://apple.github.io/coremltools/docs-guides/source/multifunction-models.html) deduplicates identical weights. Combined packages are 195,756,662 bytes (97M) and 624,742,558 bytes (311M), excluding tokenizer/compiled files. Both combined functions reproduced every vector from the separate selective functions exactly on all 102 queries and 1,677 passages.

| Model | Published variant | Pinned commit |
| --- | --- | --- |
| 97M | [mixed-fp16-v1](https://huggingface.co/rankun203/granite-embedding-97m-multilingual-r2-coreml/tree/mixed-fp16-v1/mixed-fp16) | `5f38ca7e75e2960106f4c2115a3d50c6bd0d0232` |
| 311M | [mixed-fp16-v1](https://huggingface.co/rankun203/granite-embedding-311m-multilingual-r2-coreml/tree/mixed-fp16-v1/mixed-fp16) | `b9365fd4153c21d9e0accaaee3ec078c1b3f1707` |

Hugging Face checksum verification checked all 17 newly published files in each repository. The original FP32 assets and `v1` tags remain available. Cards describe mixed floating-point precision, not integer/palette quantization, and include generic inference and reproduction instructions.

The app preserves complete queries and 512-token document windows. It loads and performs an initial query prediction during preparation, according to the General background-loading preference. The document function loads lazily. The model-space identifier changes so existing document indexes rebuild through the provider interface.

Bounded-mask/128 remains experimental. The tested 4/6-bit palettes are not published as defaults; 8-bit saves storage but has no latency advantage here. The app registry adopts the validated mixed-FP16 variant for both Granite sizes.

## Real-library app validation

An opt-in release-code harness indexed 366 authorized meetings, producing 39,066 windows with the deployed 97M model. Fresh indexing, including model preparation, took 571.89 seconds with no failed meetings. Sixteen queries each returned five results. Inputs, identities, excerpts, and detailed receipts remain local; only aggregate results are retained here.

The first complete-search measurement exposed a larger bottleneck than model inference: the app decoded JSON coordinates and scanned every window. The semantic SQLite projection now stores little-endian FP32 coordinates separately from window metadata and uses Accelerate dot products. It still evaluates every eligible window and adds the speaker bonus before selecting the top results; it keeps only one meeting's vector buffer and a bounded result set. This introduces no full-library vector cache or graph.

| Release-code search path | Median ms | Minimum ms | Maximum ms | Ordered top-five agreement |
| --- | ---: | ---: | ---: | ---: |
| JSON vectors with scalar Double scoring | 4,360.44 | 4,353.95 | 4,383.57 | Reference |
| Packed FP32 vectors with native scoring | 416.33 | 407.82 | 433.21 | 16/16 queries |

The maximum corresponding score difference was 0.0000001283. Packed vector payload is 60,005,376 bytes, and metadata payload is 23,315,099 bytes, excluding SQLite overhead and reusable per-meeting artifacts. Rebuilding the new disposable projection took 83.51 seconds through the incremental provider path, which can reuse saved embeddings. This is not a second fresh-inference throughput result.

These are single sequential passes with an already prepared model, five results per query, speaker bonuses disabled, and filesystem caches uncontrolled. They include tokenization, embedding, source validation, metadata decoding, and exact retrieval, but exclude UI scheduling. The regression suite separately verifies speaker boosting before top-K, updates, deletions, reopening and model-space separation. This sample establishes parity with the prior implementation, not comprehensive search relevance or large-library scalability. DiskANN and other approximate backends remain unmeasured candidates in the search-index-scale experiment.

# Limitations

One Mac cannot establish latency or Neural Engine placement across Apple hardware. Allowed compute units do not prove actual placement. Model inference timings exclude tokenization, database retrieval, UI scheduling, and contention from active recording or indexing. The native benchmark is not an end-to-end search trace. Cached model loading varies substantially, so neither package size nor one fresh process establishes first-install startup latency.

Queries in this set are short. The evaluation does not establish quality near the 128/512 boundaries, across other languages, or on arbitrary document lengths. The initial per-shape experiments duplicated weights; the published multifunction package removes that disk duplication. Resident memory with both functions loaded, battery use and energy per query remain unmeasured. The palette results do not cover quantization-aware training or more selective compression.

Conversion emits fixed-trace mask warnings, int64-to-int32 constant warnings and an unsupported optional embedding-argument warning. The pinned tokenizer loader also emits its Mistral-regex heuristic warning for the 311M asset. Tokenizer assets were kept identical across candidates rather than silently changing preprocessing during a precision comparison. These warnings remain documented; the completed numerical and retrieval checks bound the tested behavior, not every possible input. Core ML emitted cache-recovery messages in some device-policy runs and an ANE compilation failure for conservative 311M/512 with CPU+ANE allowed; those timings include fallback and must not be presented as successful ANE execution.
