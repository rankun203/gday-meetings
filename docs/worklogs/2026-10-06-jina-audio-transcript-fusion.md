---
title: Jina audio and transcript fusion comparison
date: 2026-10-06
status: complete
scope: audio-retrieval-experiment
---

# Problem

The comparison did not include combining Jina audio and Jina transcript rankings for the same windows.

# Implemented solution

Added equal-weight reciprocal rank fusion with constant 60 to `experiments/audio-retrieval/compare.py`, reusing saved embeddings for 50 written queries and 150 windows. Reviewed 11 newly pooled passages with method names, ranks, and scores hidden, then evaluated all methods against the complete 1,613-pair pool. Updated the existing setup, comparison matrix, relevance, language, uncertainty, ablation, and runtime sections in `RESULTS.md`, plus reproduction instructions.

The hybrid achieved 76% evidence hits at one, 90% at five, and 100% at ten; useful first results were 76% and full answer support was 64%. Jina transcript alone retained 96% evidence hits at one, 98% useful first results, and 78% full support. Fixed fusion improved audio-only retrieval but weakened transcript retrieval.

# Reasoning

The existing fusion rule permits a direct comparison without tuning against these queries. This variant was added after prior outcomes were known; it is exploratory. New judgments were completed before inspecting its score. Earlier artifacts remain intact in ignored storage. Both candidate representations are required, while the query embedding is shared; combined deployment resource costs were not measured.

# Technical debt

None. The experiment retains its stated evaluation limits: a small selected corpus, transcript-informed queries, and assistant relevance review without independent adjudication. Held-out evaluation is needed before changing app retrieval.

# Validation

Ten synthetic tests passed, including equal-weight dense fusion and corpus-mismatch rejection. All 1,613 judgments passed completeness and validity checks. The report's three method tables were generated from the final metrics. No encoder inference or app changes were needed.
