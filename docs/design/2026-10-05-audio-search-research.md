---
title: Audio retrieval models and provider architecture
date: 2026-10-05
status: research-and-proposal
scope: meeting-search
---

# Recommendation

Evaluate CLSP first for descriptions of speaking style. Evaluate a speech-semantic encoder separately for meaning in original audio. Keep lexical text search as the fast baseline and combine independently ranked results through reciprocal rank fusion (RRF). Do not reuse the speaker-association vectors as text-query vectors: their training objective and embedding space differ.

The source review is supplemented by a local CPU smoke test on three synthesized clips. Pinned weights were downloaded; no meeting recordings were uploaded. This does not reproduce a published retrieval benchmark. The maintainer selected a local Python worker before considering native conversion.

# Three retrieval tasks

| Task | Representation | Example query |
| --- | --- | --- |
| Audible delivery and timbre | Speech-style/audio-language embeddings | A soft, high-pitched voice speaking quickly |
| Meaning of spoken words, including missing transcript content | Speech and text encoders aligned by linguistic meaning | The delivery date was postponed |
| The same known speaker across recordings | Existing typed speaker-identity embeddings | Find more excerpts from this assigned person |

A description of a voice may retrieve similar-sounding excerpts, but cannot establish actual age, gender identity, or an employment role. A role such as intern requires supplied metadata. Search results should be playable evidence with timestamps, not new demographic labels saved to People. Overlap, compression, microphones, and language can change retrieval quality.

# Candidate comparison

| Candidate | Evidence and fit | Deployment and limitations |
| --- | --- | --- |
| **CLSP** | Released speech/text dual encoder designed for fine-grained speaking-style retrieval; the closest task fit to descriptive voice queries. | Model card lists Apache-2.0, about 0.7B parameters, English, and 16 kHz input. Config uses a 512-dimensional joint space. Custom PyTorch/Transformers code needs review and a pinned revision. Native Core ML/MLX support and Mac latency are unverified. |
| **LAION CLAP** | Useful general audio/text retrieval baseline, with published speech-inclusive checkpoints. | General sound-event performance does not establish reliable voice-style retrieval or spoken semantic understanding. Check exact checkpoint licensing and preprocessing before deployment. |
| **AF-CLAP / Audio Flamingo** | Stronger compositional audio-language representations are relevant for complex acoustic descriptions. | NVIDIA's repository distinguishes MIT code from noncommercial checkpoints. Research comparison candidate; not an assumed shipping dependency. |
| **SONAR** | Aligns speech and text in a sentence-level semantic space; relevant when ASR misses content. | Language-specific speech encoders and licensing vary. Code and some speech encoders are MIT; others and text models have separate terms. Not designed as a timbre-description model. |
| **Jina v5 omni small** | Released multimodal retrieval encoder accepting audio and text in a shared space; worth testing for semantic audio retrieval. | About 1.74B parameters, 1024-dimensional output with supported smaller dimensions. Open weights are CC-BY-NC-4.0; commercial deployment terms differ. Python inference documented; Mac conversion and performance unverified. |
| **Omni-Embed-Nemotron / Omni-Embed-Audio** | Multimodal retrieval and research on real search-query phrasing offer a broader comparison. | NVIDIA's base model card specifies research/development use and noncommercial terms. Considerable runtime footprint; not a default local dependency. Fine-tuned derivatives must be reviewed separately. |

Primary sources reviewed October 5, 2026:

- [CLSP authors' repository](https://github.com/yfyeung/CLSP), [model card](https://huggingface.co/yfyeung/CLSP), [configuration](https://huggingface.co/yfyeung/CLSP/blob/main/config.json), and [paper](https://arxiv.org/abs/2601.03065).
- [LAION CLAP authors' repository](https://github.com/LAION-AI/CLAP).
- [Audio Flamingo 2 research](https://research.nvidia.com/labs/adlr/AF2/) and [repository license distinction](https://github.com/NVIDIA/audio-flamingo).
- [SONAR authors' repository](https://github.com/facebookresearch/SONAR) and [per-model license listing](https://github.com/facebookresearch/SONAR/blob/main/LICENSE.md).
- [Jina v5 omni small model card](https://huggingface.co/jinaai/jina-embeddings-v5-omni-small).
- [NVIDIA model card](https://huggingface.co/nvidia/omni-embed-nemotron-3b) and [Omni-Embed-Audio authors' repository](https://github.com/JudeJiwoo/Omni-Embed-Audio).

The recommendation is an inference from task fit, available artifacts, and integration constraints. Published general-audio metrics cannot settle quality on meeting speech. Do not equate a permissive code license with identical rights for every weight, tokenizer, or dependency.

# Index construction

1. Derive short, overlapping audio windows from original track timelines. Prefer isolated speaker turns for voice descriptions; retain an overlap marker rather than assigning mixed speech to one person. Start experiments with 5–15 second windows, then tune against model requirements and measured retrieval quality.
2. Save provider artifacts under the data folder, containing stable meeting/track references, start/end, source digest, model and preprocessing revisions, embedding space, dimension, normalization, and vectors. Write atomically; preserve completed artifacts across cancellation. Do not duplicate the original audio unnecessarily.
3. Project these artifacts into namespaced tables in the shared `index.db`. Filtering by library exclusions, source revision, and embedding space precedes ranking. A matching dimension alone never establishes compatibility.
4. Begin with bounded exact similarity scans and incremental indexing. Load models only on explicit indexing/query use. A second database cannot solve eager model loading.
5. Consider an ANN index only after benchmarking. Treat HNSW graphs as rebuildable accelerators; retain exact vectors, rerank candidates, and measure recall against exhaustive search. Open an optional `index-l2.db` lazily only if measurements justify separating its lifecycle.

The maintainer confirmed cloud-backed data folders retain source artifacts and embeddings while active SQLite files remain local to each Mac. Generated `index.db.md` describes the real location, schema, versions, and read-only query examples. It contains no meeting content or credentials.

# Provider and streaming contract

Every search path uses a capability adapter, including built-in local text search. Configuration records supported modalities, index readiness, source scope, model revision, destination, and indexing policy. Provider schema modules register through the database owner; a remote endpoint cannot execute arbitrary SQL.

The UI offers Text, Voice, and Fusion. Text can include transcript/summary filters while preserving existing title/notes retrieval. Voice uses the configured audio retrieval provider; unavailable setup is explicit. Fusion runs selected providers concurrently and combines ranks, not incomparable raw similarity scores.

Each request has a stable request ID and bounded result limit. Each event identifies its provider, increasing sequence, ranked snapshot, completion state, and data-flow receipt. A single-shot provider sends one final snapshot. Progressive events replace that provider's prior snapshot; they never add repeated rank contributions. Cancellation and query generation checks reject late events. Partial failures preserve successful sources and clearly report incomplete coverage.

Use RRF score `sum(weight / (k + rank))`, with one-based ranks and deterministic ties. Start with `k = 60` as a configurable baseline, not a quality claim. Fuse at a documented granularity: use meeting identity for meeting-level ranking and retain the best source-specific passages as evidence. A meeting with many chunks must not receive many votes from the same provider. Initial results may reorder as slower providers finish; preserve selection by stable identity and avoid moving keyboard focus.

Index preparation, source changes, cancellation, invalidation, and removal are explicit operations. A successful query does not mean the whole library is indexed. Remote metadata checks do not send audio or text. Remote indexing sends only explicitly selected sources; saved configuration alone does not start an upload.

# Evaluation before a model ships

Use licensed or synthetic clips with a held-out relevance set. Include similar voices, short utterances, overlap, silence, microphone changes, accents/languages, and negative examples. Separate acoustic-description queries from semantic queries and known-speaker queries.

Measure Recall@10, nDCG@10, query latency (cold/warm), time to first results, index throughput, memory, disk growth, and startup overhead. Compare lexical search, each embedding provider, and RRF. For semantic tests, deliberately remove key text from the fixture transcript while keeping the recorded utterance; verify retrieval from the original audio. For acoustic tests, vary delivery while holding words constant and vary words while holding the speaker constant. This distinguishes voice retrieval from transcript leakage.

Do not report identities or demographic accuracy from similarity scores. Listen to returned excerpts and keep human relevance judgments separate from generated captions. A model may support the API yet fail the intended retrieval task.

# Open decisions

- Whether measured retrieval quality and indexing cost justify shipping the selected local Python prototype or converting it to native inference.
- A deployable speech-semantic model with acceptable language coverage, terms, and Mac performance.
- ANN extension and L2 database only after exact-search measurements.

# Technical debt

The optional Python worker introduces pinned model/runtime dependencies for evaluation, with upstream deprecation warnings documented below. Basic index/search integration is implemented and tracked in the shared-index worklog; retrieval quality and real-library throughput remain unvalidated. The existing eager voice catalog remains a separate storage limitation. Avoid an unvalidated bundled model, a second authoritative store, and a decorative Voice mode backed only by text search.

## Local CPU smoke test

A pinned CLSP worker ran on macOS 26.6.2 arm64 with four CPU threads. Three synthesized clips contain identical generic words, with two delivery speeds in one voice and a second voice. Results and logs are in `tmp/audio-search-research-2026-10-05/`. This small fixture checks execution and sensitivity, not meeting retrieval quality.

- Total process measurement: 19.44 seconds; peak resident memory: 3.20 GB (decimal).
- Model construction: 0.56 seconds with downloaded files already cached. This excludes imports and deferred first-use work and is not a cold-start estimate.
- First text batch: 0.52 seconds; warm text batch: 0.040 seconds.
- Audio embeddings: 7.00, 4.98, and 2.07 seconds for the three short clips. Clip lengths differ; these are not comparable throughput measurements.
- Within the same voice, the slow query scores the slow clip above the fast clip (0.227 versus 0.074), and the fast query reverses them (0.458 versus 0.314). The second voice ranks first for both queries. Cross-speaker delivery retrieval therefore remains unvalidated.

The worker explicitly freezes both encoders under `torch.no_grad()`. Upstream encoders enable gradients unless instructed otherwise; combining that behavior with inference-mode tensors failed the first audio run. Four upstream AMP decorator deprecation warnings remain visible. PyTorch's supported replacements are `torch.amp.custom_fwd` and `custom_bwd` with an explicit device type. Keep the reviewed model revision for this experiment; obtain an upstream fix or review a reproducible patch before distributing the worker. Do not silently modify downloaded model code. [PyTorch AMP documentation](https://docs.pytorch.org/docs/2.8/amp.html).
