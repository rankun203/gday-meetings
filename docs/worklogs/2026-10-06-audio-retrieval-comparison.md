---
title: Audio retrieval model and lexical comparison
date: 2026-10-06
status: evaluated-with-limits
scope: retrieval-evaluation
---

# Problem

The previous CLSP conversion evaluation preserved weak meeting-topic retrieval. Its original positive labels did not establish whether other returned windows were relevant. Alternative audio models and lexical methods need a common comparison.

# Implemented solution

Added standalone encoders, lexical and hybrid comparisons, and explicit evidence and graded-relevance metrics under `experiments/audio-retrieval/`. Private corpus data, embeddings, rankings, and judgments remain in ignored temporary storage. Reuse the existing evaluation windows and queries. Do not change the app or installed model.

# Reasoning

Separate direct audio retrieval from retrieval over existing transcripts. Keep checkpoint revisions, preprocessing, corpus, and fusion constants fixed before relevance review. Use blinded pointwise and pairwise review, evidence-support checks, and scenario-level uncertainty. Treat unjudged windows as unknown rather than negative.

# Technical debt

The benchmark retains the earlier evaluation's nonexhaustive evidence labels and transcript-derived scenario selection. This supports paired exploratory comparisons but cannot establish general production quality or acoustic fidelity. Remediation: independently labeled, held-out meetings with human listening review and a broader corpus before selecting a production model.

# Progress

- Reviewed repository writing requirements and the previous benchmark artifacts.
- Reviewed current primary model documentation and pinned candidate checkpoint revisions.
- Completed 12 methods: three direct-audio model families, transcript embeddings, three lexical baselines, chunk pooling variants, and fixed rank-fusion combinations. Results are in [the comparison report](../../experiments/audio-retrieval/RESULTS.md).
- Jina audio evidence hit rate at ten was 86%, versus CLSP's 8%. Jina transcript reached 100%, BM25 84%, and E5 transcript 86%. Fixed BM25 fusion degraded Jina transcript cross-language retrieval.
- Completed 1,438 blinded pointwise relevance and evidence-support judgments, plus 30 pairwise comparisons and ten reversed-order checks. Found 11 useful pairs missing from the original labels. Three exact discussion matches only ask the question; seven more need qualifications or context. Reported these separately from answer support.
- Scenario-clustered bootstrap intervals use ten scenarios, 10,000 resamples, and a fixed seed. Reported language slices and strict/broad relevance thresholds. No weight tuning or model fine-tuning used the evaluation queries.
- Eight synthetic tests passed. Reproduced the prior CLSP matrix and evidence metrics; checked finite unit vectors and input fingerprints. Nine Jina CPU/Metal probes, nine Jina Metal repeat probes, and six CLAP CPU/Metal probes passed numerical checks. No Swift code changed, so release-app validation was not required.
- Archived private inputs, rankings, source snapshot, model-file hashes, judgments, timing records, and probe results under ignored `tmp/audio-retrieval-benchmark-2026-10-06/`. Nothing was uploaded. App state was not changed.
- Revised `RESULTS.md` into a self-contained report with a brief literature review, experiment setup, paragraph definitions for every method and metric, and ablation comparisons drawn from the existing measurements. Defined the exact Jina checkpoint, its audio and transcript input paths, preprocessing, pooling, and ranking; no scores or judgments changed.
- Added a concise experiment format to `AGENTS.md`: runnable source, `README.md`, and `RESULTS.md` with findings, references, setup, results, definitions, and useful ablations. Added generic ignore rules for local experiment inputs, model files, caches, and run artifacts while retaining reports and synthetic fixtures.

# Validation notes

Publication checks passed for Markdown front matter, local links, whitespace, and private transcript/query content. Generic ignore rules were checked against a synthetic experiment name; reports, scripts, and synthetic fixtures remain trackable. The eight benchmark tests passed again before committing.

The initial Jina tokenizer load emitted a custom-code prompt even though model code had already been reviewed and enabled. Made that choice explicit for tokenizer loading; the repeat produced identical vectors without the prompt. The original executed script is retained with its run manifest hash in private artifacts.

A temporary package-inventory helper encountered a missing-metadata deprecation. Checked the [upstream removal notice](https://importlib-metadata.readthedocs.io/en/latest/history.html#v8-0-0), replaced missing-key indexing with explicit optional-field handling, removed duplicate installer entries, and reran the export successfully. No deprecation warning remained in the new inference or scoring runs. Initial unauthenticated model-download notices remain in logs; these concern rate limits rather than inference correctness.

Timings are observational: E5 used CPU, audio models used Metal, and some runs overlapped. Transcript timing excludes ASR. Jina's noncommercial checkpoint terms and native Swift/Core ML feasibility remain production-adoption gates. Review used transcripts, not listening or independent adjudication; these are explicit evaluation limits, not a claim that the app is ready to switch models.
