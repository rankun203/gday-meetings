---
title: Audio and transcript retrieval comparison
date: 2026-10-06
status: evaluated-with-limits
scope: local-retrieval-model-selection
---

# Findings

Jina v5 omni nano retrieval is the strongest direct-audio model tested. It found the labeled window in the first ten results for 86% of queries, compared with 8% for CLSP. Its transcript embeddings performed better still: 96% first-result evidence hits and 100% within ten results. CLAP did not improve meeting-topic retrieval.

Lexical retrieval is a strong baseline when query and recording languages match. BM25 achieved 84% evidence hits within ten results overall, but only 42.9% for cross-language queries. Fixed equal-weight lexical fusion reduced Jina transcript retrieval quality. It should not be adopted by default on the strength of the same-language result.

These results support further evaluation of Jina for direct audio search and transcript embeddings for topic search. They do not establish a production-ready replacement. Jina's checkpoint has noncommercial terms; any commercial app use needs the appropriate rights. No app model, index, or installed application was changed.

# References

**Speech style versus spoken content.** [Yang et al., *Towards Fine-Grained and Multi-Granular Contrastive Language-Speech Pre-training*](https://arxiv.org/abs/2601.03065) introduces CLSP, a contrastive language–speech model for describing how speech sounds, including speaking style. Contrastive training brings matched audio and text representations closer together while separating mismatched pairs. Its [model card](https://huggingface.co/yfyeung/CLSP) motivates retaining CLSP as the existing baseline, but its style objective does not establish that it can retrieve the facts discussed in a meeting.

**General audio–text retrieval.** [Wu et al., *Large-scale Contrastive Language-Audio Pretraining with Feature Fusion and Keyword-to-Caption Augmentation*](https://arxiv.org/abs/2211.06687) describes CLAP, contrastive language–audio pretraining. It aligns recordings with text descriptions of audio. This provides a different direct-audio baseline; success on audio-caption retrieval is not assumed to transfer to detailed meeting-topic queries. This experiment uses LAION's HTSAT unfused checkpoint, where HTSAT identifies its hierarchical audio transformer encoder.

**Shared audio and text embeddings.** [Hönicke et al., *jina-embeddings-v5-omni: Geometry-preserving Embeddings via Locked Aligned Towers*](https://arxiv.org/abs/2605.08384) describes adding audio and visual encoders to a text embedding model through trained connecting components while keeping the encoders frozen. This motivates testing audio and transcript inputs with the same retrieval checkpoint. “Jina” throughout this report means `jinaai/jina-embeddings-v5-omni-nano-retrieval`; the two input paths are defined below.

**Multilingual text retrieval.** [Wang et al., *Multilingual E5 Text Embeddings: A Technical Report*](https://arxiv.org/abs/2402.05672) describes a family of text embedding models trained for multilingual retrieval. The small E5 checkpoint provides a separate transcript baseline, helping distinguish benefits of using recognized words from benefits specific to Jina. Neither model's published benchmark scores are included in this report's measured results.

**Lexical ranking and combining rankings.** Manning, Raghavan, and Schütze's *Introduction to Information Retrieval* describes [BM25](https://nlp.stanford.edu/IR-book/html/htmledition/okapi-bm25-a-non-binary-model-1.html), which scores shared terms while accounting for their frequency and document length. [Cormack, Clarke, and Buettcher, *Reciprocal Rank Fusion Outperforms Condorcet and Individual Rank Learning Methods*](https://plg.uwaterloo.ca/~gvcormac/cormacksigir09-rrf.pdf) proposes combining result lists by rank rather than comparing incompatible raw scores. These motivate lexical baselines and fixed fusion variants; their published gains do not guarantee an improvement on this corpus.

**Ranking evaluation.** The textbook's [evaluation of ranked retrieval results](https://nlp.stanford.edu/IR-book/html/htmledition/evaluation-of-ranked-retrieval-results-1.html) distinguishes recovering relevant documents from placing them early in a list, and discusses graded relevance. This report therefore separates original evidence labels, graded passage relevance, and whether the returned passage supports an answer. The exact metric definitions and review procedure below govern this experiment.

# Experiment setup

**Task and corpus.** A query is a written request to find a discussion in a recording. A window is a contiguous audio clip; its passage is the existing transcript text for that same interval. The corpus is the shared collection of 150 candidate windows searched for every query. Ten scenarios group the source meeting contexts and their queries, with five queries per scenario. The experiment reuses the previous CLSP evaluation's 50 queries, 50 distinct labeled positive windows, and 100 additional windows whose relevance was initially unknown. A positive is a window originally labeled relevant to a query, not a claim that all other windows are irrelevant.

**Selection and language groups.** Scenarios were selected using meeting summaries, and query construction used transcript context. This is an exploratory comparison, with no held-out test split, fine-tuning, or parameter search. There are 25 English and 25 Chinese queries. Fourteen are cross-language: the query language differs from the target scenario's recorded language; the other 36 are same-language. Actual passages can contain both languages. These groups measure retrieval across language labels, not the quality of translation.

**Shared retrieval procedure.** An embedding is a numerical vector produced by a trained encoder. Dense retrieval compares query and candidate vectors by cosine similarity, their directional agreement; vectors are normalized to length one, making cosine equal to their dot product. Each method scores all 150 candidates directly, without an approximate search index or a second ranking model. A token is a unit of text used by an encoder; pooling reduces token or chunk representations to one vector. The audio inputs are identical decoded mono waveforms at 16,000 samples per second, lasting 0.35–29.74 seconds. Transcript methods use the existing automatic speech recognition (ASR) output for those intervals. No method translates queries, expands them, generates summaries, or reruns ASR.

**CLSP audio.** The existing `yfyeung/CLSP` checkpoint at [revision `30355ce`](https://huggingface.co/yfyeung/CLSP/tree/30355ce67960e4cc1562e4e5fa154baf86a21430) encodes each complete audio window and the unprefixed query into 512-dimensional vectors. This comparison reuses its original Python reference embeddings and similarity matrix, already checked against native Core ML inference in the [earlier evaluation](../../docs/worklogs/2026-10-06-clsp-coreml.md). It does not encode the transcript or retrain the model for meeting topics.

**Jina audio.** The Jina retrieval checkpoint at [revision `b7287f6`](https://huggingface.co/jinaai/jina-embeddings-v5-omni-nano-retrieval/tree/b7287f6b6b562e25bc4a28b939d1f936484b4137) turns the full audio window into 128-channel time–frequency features, then audio-token representations for the shared embedding model. A mask identifies real audio frames so padding to the 30-second processing window does not count as speech. The audio prompt uses `Document: ` and the model's audio markers; the text query uses `Query: `. The final valid token's representation is normalized to a 768-dimensional vector. Retrieval compares that query vector directly with each audio vector, without producing a transcript.

**Jina transcript.** This uses the text encoder of the same pinned Jina omni retrieval checkpoint. Each candidate is its existing window transcript prefixed with `Document: `; each query is prefixed with `Query: `. Both are tokenized with a limit of 8,192 tokens, encoded, and reduced to the last valid token's normalized 768-dimensional representation. Cosine similarity ranks the transcript vectors, and each result points back to its corresponding audio window. Thus “Jina transcript” measures semantic search over recognized words, with ASR quality and cost outside this run.

**E5 transcript.** `intfloat/multilingual-e5-small` at [revision `614241f`](https://huggingface.co/intfloat/multilingual-e5-small/tree/614241f622f53c4eeff9890bdc4f31cfecc418b3) encodes queries with `query: ` and window transcripts with `passage: `. Inputs are limited to 512 tokens. Masked mean pooling averages the valid token representations, excluding padding, and normalizes the resulting 384-dimensional vector. Query-to-transcript cosine similarity ranks windows. It receives the same existing transcripts as Jina transcript.

**CLAP audio variants.** `laion/clap-htsat-unfused` at [revision `8fa0f1c`](https://huggingface.co/laion/clap-htsat-unfused/tree/8fa0f1c6d0433df6e97c127f64b2a1d6c0dcda8a) receives unprefixed text queries and audio resampled to 48,000 samples per second. Each window is split into consecutive chunks of at most ten seconds and processed with the checkpoint's audio frontend, yielding normalized 512-dimensional vectors. **Maximum chunk similarity** assigns a window its highest query–chunk cosine score. **Mean chunk embedding** averages its chunk vectors with equal weights, normalizes that average, and compares it with the query. Both retain every chunk; the comparison tests pooling rather than selecting a favorable crop.

**BM25 transcript.** BM25 is a lexical method: candidates score through shared terms rather than learned semantic embeddings. This implementation lowercases Latin text, extracts Latin words and numbers, and represents Chinese runs with individual characters plus adjacent character pairs. It weights rarer terms more strongly, saturates repeated-term contributions with `k1=1.2`, and adjusts for passage length with `b=0.75`. It scores the existing window transcripts, with each distinct query term contributing once. No stemming or stop-word removal is applied.

**TF-IDF transcript variants.** Term frequency–inverse document frequency (TF-IDF) weights a feature by its occurrence within a passage and its rarity across the corpus. Here term frequency uses `1 + log(count)`, document-frequency weights are smoothed, and vectors are normalized before cosine scoring. **Word TF-IDF** uses the BM25 tokenizer and both single tokens and adjacent token pairs; despite its name, its Chinese features are based on characters. **Character TF-IDF** uses lowercased sequences of two to four consecutive characters, including spaces and punctuation. An n-gram is such a sequence of n units. Vocabulary and frequency statistics are fitted on the 150 candidate transcripts only.

**Hybrids and rank fusion.** A method name containing `+ BM25` combines that embedding method's ranking with BM25 using reciprocal rank fusion (RRF). Each candidate receives the sum of `1 / (60 + rank)` across the two lists, with ranks starting at one and equal method weights. A candidate absent from a list contributes zero for that list. Dense lists contain all 150 windows; lexical lists omit zero-score matches. A fixed SHA-256 hash of the candidate identifier breaks tied scores consistently without favoring the original corpus order. All constants and variants were fixed before relevance review.

**Evidence and relevance metrics.** `@k` means the first k ranked results. **Evidence hit rate @k** is the fraction of queries whose top k includes an original labeled positive; **recall @k** is the fraction of each query's positives recovered, averaged across queries. They coincide here because each query has one positive. **Mean reciprocal rank (MRR)**, saved in the detailed results, averages `1 / rank` of the first positive; missing positives contribute zero, and MRR @10 also counts ranks beyond ten as zero. **Useful first result** requires review grade 2 or 3; **useful precision @5** is the number of such results divided by five, averaged across queries. **Direct-discussion precision @5** counts only grade 3. Missing result slots contribute zero. The grade rubric is reported in [Relevance assessment](#relevance-assessment).

**Graded ranking and answer support.** Normalized discounted cumulative gain (**nDCG**) rewards higher relevance grades near the start of a list. This implementation sums `(2^grade − 1) / log2(rank + 1)` over five results, then divides by the maximum possible sum from the judged pool for that query. **Pooled nDCG @5** averages those ratios; it does not assume judgments exist for every corpus pair. **Full support @1** is the fraction of all queries whose first result supplies the requested details. Support is assessed separately as full, partial, question-only, absent, or contradictory: even a direct discussion match may only repeat the question. No answers are generated or graded in this experiment.

**Execution and reproducibility.** All inference is local, in float32 (32-bit floating-point arithmetic), using PyTorch 2.14.1 and Transformers 5.18.0. Jina and CLAP use the Mac GPU through Metal; E5 uses four CPU threads. [encode.py](encode.py) implements the encoders, [compare.py](compare.py) implements rankings and metrics, and [summarize.py](summarize.py) computes uncertainty and pairwise summaries. [requirements.txt](requirements.txt) pins the runtime environment; [README.md](README.md#running) provides commands. Private inputs and detailed artifacts remain under ignored `tmp/audio-retrieval-benchmark-2026-10-06/`, including input/model hashes, embeddings, rankings, judgments, and timings. The report and scripts can be shared; reproducing the measured scores also requires the private inputs and judgments.

# Comparison matrix

The same 50 queries search the same 150 windows. Each original query has one labeled window, so evidence hit rate and recall are numerically equal here. “Useful first result” is the assistant's blinded transcript judgment at grade 2 or 3. “Full support” requires the passage to support the requested details, rather than merely discuss the subject or repeat the question.

| Method | Evidence @1 | Evidence @5 | Evidence @10 | Cross-language evidence @10 | Useful first result | Full support @1 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| CLSP audio, existing reference | 2% | 4% | 8% | 0% | 2% | 2% |
| CLAP audio, maximum chunk similarity | 0% | 2% | 6% | 14.3% | 0% | 0% |
| CLAP audio, mean chunk embedding | 0% | 0% | 6% | 7.1% | 0% | 0% |
| **Jina audio** | **48%** | **82%** | **86%** | **85.7%** | **50%** | **44%** |
| BM25 transcript | 68% | 84% | 84% | 42.9% | 68% | 54% |
| Word TF-IDF transcript | 70% | 84% | 84% | 42.9% | 70% | 54% |
| Character TF-IDF transcript | 72% | 80% | 82% | 42.9% | 72% | 60% |
| Multilingual E5 small transcript | 78% | 84% | 86% | 50% | 82% | 60% |
| **Jina transcript** | **96%** | **100%** | **100%** | **100%** | **98%** | **78%** |
| E5 transcript + BM25 | 78% | 80% | 82% | 35.7% | 80% | 60% |
| Jina audio + BM25 | 70% | 84% | 88% | 57.1% | 70% | 58% |
| Jina transcript + BM25 | 84% | 84% | 90% | 64.3% | 84% | 66% |

# Relevance assessment

The reviewing assistant read the 150 passages and 50 queries in independently shuffled catalogs, with source IDs replaced and model identities, ranks, scores, and original positive labels hidden. This is a blinded review: the judgment uses the query and passage without knowing which retrieval method returned it. Query–passage combinations were assessed before inspecting the method score table. The judgment pool is the union of each method's top five, the original positives, and one repeatable random control per query. A control is an additional sampled window, not a presumed negative. After deduplication the pool contains **1,438 pairs**. All pairs were graded; none were silently treated as an unjudged negative.

The grades were 0 unrelated or misleading, 1 related topic without useful evidence, 2 useful partial evidence, and 3 direct match to the requested discussion. There were 1,248 grade-0, 129 grade-1, 11 grade-2, and 50 grade-3 pairs. All 11 useful partial matches were absent from the original positive labels. This explains why evidence hit rate and useful-first-result rate differ.

| Method | Useful precision @5 | Direct-discussion precision @5 | Pooled nDCG @5 |
| --- | ---: | ---: | ---: |
| CLSP audio | 0.8% | 0.8% | 0.045 |
| CLAP audio, maximum | 0.4% | 0.4% | 0.012 |
| CLAP audio, mean | 0% | 0% | 0.006 |
| Jina audio | 18.0% | 16.4% | 0.629 |
| BM25 transcript | 18.8% | 16.8% | 0.692 |
| Word TF-IDF transcript | 19.2% | 16.8% | 0.705 |
| Character TF-IDF transcript | 18.8% | 16.0% | 0.708 |
| E5 transcript | 19.2% | 16.8% | 0.754 |
| Jina transcript | 24.0% | 20.0% | 0.943 |
| E5 transcript + BM25 | 18.8% | 16.0% | 0.741 |
| Jina audio + BM25 | 18.4% | 16.8% | 0.707 |
| Jina transcript + BM25 | 19.6% | 16.8% | 0.788 |

The precision values reflect sparse relevant material: the judged pool contains only 61 useful pairs across 50 queries, making its ideal precision at five 24.4%. Do not read 24% as evidence that Jina misses most known relevant material. Conversely, pooled nDCG uses the judged pool as its ideal ranking; it is not exhaustive-corpus nDCG.

## Evidence support and answerability

The same assistant separately assessed whether each passage supports the query's requested details. Three direct matches only ask the question; they provide no answer. Seven other direct matches need qualifications or context, including a cut-off explanation, ambiguous transcribed product names, and a procedure that omits one requested check. Forty direct matches fully support the requested details as a record of what was said. This does not independently verify the real-world truth of the speaker's claims.

Jina transcript retrieval returned full support first for 39 of those 40 queries, or 78% of all 50 queries. A system that finds the correct discussion must still abstain from inventing an answer when that discussion does not contain one. Private judgments retain supporting passages and explanations for partial, question-only, and unsupported results.

## Blinded pairwise review

Pairwise review compares two passages for the same query and chooses the more useful and complete evidence. One query per scenario was selected using a fixed hash, then three predetermined method pairs were compared at rank one. The assistant reviewed all 30 pairs and ten additional left/right reversals with method identities hidden. A useful tie means both results were equally useful; both unhelpful means neither supplied useful evidence. Reversing the displayed order checks whether the preference changes merely because a result appears first.

| Comparison | First method wins | Second method wins | Useful tie | Both unhelpful |
| --- | ---: | ---: | ---: | ---: |
| Jina audio versus E5 transcript | 1 | 6 | 2 | 1 |
| BM25 versus E5 transcript | 0 | 0 | 8 | 2 |
| CLSP audio versus Jina audio | 0 | 3 | 0 | 7 |

All ten reversed comparisons retained the same outcome. These checks support consistency; they are not independent judgments, do not establish inter-rater agreement, and do not replace a larger pairwise study.

# Language and uncertainty

There are 25 English and 25 Chinese queries, including 14 whose language differs from the target scenario's language. The same-language group contains 36 queries. Languages are based on existing scenario metadata; code-switching within a passage is not a separately labeled subgroup.

| Method | English evidence @1 | Chinese evidence @1 | Same-language evidence @1 | Cross-language evidence @1 |
| --- | ---: | ---: | ---: | ---: |
| CLSP audio | 4% | 0% | 2.8% | 0% |
| Jina audio | 52% | 44% | 44.4% | 57.1% |
| BM25 | 72% | 64% | 91.7% | 7.1% |
| E5 transcript | 92% | 64% | 94.4% | 35.7% |
| Jina transcript | 96% | 96% | 97.2% | 92.9% |
| Jina transcript + BM25 | 88% | 80% | 100% | 42.9% |

The **scenario-clustered paired bootstrap** estimates uncertainty in the difference between two methods while preserving related queries as a group. Each resample draws ten scenarios with replacement and retains every query from each drawn scenario; both methods are evaluated on that same resample. The reported 95% interval spans the 2.5th to 97.5th percentiles of 10,000 resampled differences, using random seed 42. This avoids treating five queries from one meeting context as five independent scenarios.

| Paired difference | Evidence @10 difference | Useful-first-result difference |
| --- | ---: | ---: |
| Jina audio minus CLSP audio | +78 pp [66, 90] | +48 pp [38, 58] |
| Jina audio minus BM25 | +2 pp [−12, 16] | −18 pp [−32, −4] |
| Jina transcript minus E5 transcript | +14 pp [4, 24] | +16 pp [8, 26] |
| Jina transcript minus BM25 | +16 pp [8, 24] | +30 pp [20, 40] |
| Jina audio + BM25 minus Jina audio | +2 pp [−12, 16] | +20 pp [6, 34] |
| Jina transcript + BM25 minus Jina transcript | −10 pp [−18, −2] | −14 pp [−22, −6] |

“pp” means percentage points. These are exploratory intervals from ten selected scenarios, without adjustment for multiple comparisons. The two-point overall difference between Jina audio and BM25 is not persuasive evidence that one has better evidence coverage. Their first-result and cross-language behaviors differ more substantially.

# Ablation comparisons

An ablation holds the rest of an experiment fixed while changing or removing a component to inspect its effect. These comparisons reuse the measured variants above; no models were retrained and no weights were tuned after seeing the results. The Jina input comparison changes the representation of each candidate from waveform to existing transcript. The fusion comparisons add one lexical ranking, and the CLAP comparison changes only chunk pooling.

| Change | Evidence @10, before → after | Useful first result, before → after | Interpretation on this corpus |
| --- | ---: | ---: | --- |
| Jina audio → Jina transcript | 86% → 100% | 50% → 98% | Recognized words improve both coverage and the first result; transcription cost is excluded. |
| CLAP maximum → mean chunk pooling | 6% → 6% | 0% → 0% | Neither pooling choice makes CLAP useful for these topic queries. |
| E5 transcript → E5 transcript + BM25 | 86% → 82% | 82% → 80% | Fixed lexical fusion does not improve this baseline. |
| Jina audio → Jina audio + BM25 | 86% → 88% | 50% → 70% | First results improve overall, while cross-language coverage falls from 85.7% to 57.1%. |
| Jina transcript → Jina transcript + BM25 | 100% → 90% | 98% → 84% | Fusion weakens the best measured method, especially across languages. |

The audio-to-transcript comparison includes the benefit of existing ASR and the transcript-informed query construction. It does not isolate an architectural advantage of Jina's text encoder. The fusion comparisons test one fixed RRF configuration, not every possible hybrid strategy.

# Runtime and deployment considerations

New model inference ran locally in float32 with PyTorch 2.14.1 and Transformers 5.18.0. Jina and CLAP used Metal; E5 used four CPU threads. Some audio runs overlapped, so timings are observations, not controlled speed comparisons or native-app latency estimates. Input windows range from 0.35 to 29.74 seconds, with 3,676.70 seconds of audio in total.

| Model | Checkpoint bytes, decimal GB | Median query encoding | Median window encoding | Window encoding p95 |
| --- | ---: | ---: | ---: | ---: |
| Jina, direct audio | 1.895 | 16.9 ms | 519.4 ms | 778.5 ms |
| Jina, existing transcript | same checkpoint | 16.9 ms | 18.0 ms | 70.3 ms |
| CLAP, all chunks in a window | 0.615 | 24.5 ms | 115.6 ms | 142.8 ms |
| E5, existing transcript | 0.471 | 11.1 ms | 15.5 ms | 21.2 ms |

**Timing and storage measures.** Median is the middle measured duration, and p95 is the 95th percentile. Encoding durations include preprocessing, inference, and transfer of the resulting vector to CPU memory; audio encoding also includes reading the clip. They exclude model loading, downloads, and saving output files. Each distribution includes its first inference call, so it is not a warm-only timing sample. Transcript timings exclude transcription. A checkpoint is the saved model parameters; decimal GB means one billion bytes. Checkpoint bytes are not peak RAM, download totals, or a Core ML bundle converted for native Apple-platform inference. Existing CLSP native timings were collected in another execution context and are not used for a speed ratio.

The pinned [Jina checkpoint](https://huggingface.co/jinaai/jina-embeddings-v5-omni-nano-retrieval/tree/b7287f6b6b562e25bc4a28b939d1f936484b4137) declares CC BY-NC 4.0; the publisher directs commercial users to obtain commercial terms. The pinned [CLAP model](https://huggingface.co/laion/clap-htsat-unfused/tree/8fa0f1c6d0433df6e97c127f64b2a1d6c0dcda8a) declares Apache 2.0 and [E5 model](https://huggingface.co/intfloat/multilingual-e5-small/tree/614241f622f53c4eeff9890bdc4f31cfecc418b3) declares MIT. No new Core ML conversion or Swift inference implementation was evaluated here.

# Validation and limitations

- Verified the CLSP reference matrix against saved reference embeddings in current query/corpus order; maximum recomputation difference was below 0.000001. Its original 2%/4%/8% evidence result reproduced.
- Checked all new output vectors for finite values and unit normalization. Recorded checkpoint revisions, model-file hashes, source hashes, input hashes, package versions, and per-item timings. No overlapping audio-window intervals were found within a scenario.
- Rechecked Jina across CPU and Metal on three queries, three transcripts, and three audio windows. Agreement exceeded cosine 0.999999999 on these probes. A separate Metal repeat checked the explicit reviewed-tokenizer loading path. This is a small inference check, not native-conversion validation.
- Rechecked CLAP across CPU and Metal on three queries and three audio windows; minimum cosine exceeded 0.999999999. Eight synthetic tests passed for evidence recall, lexical abstention, deterministic ties, incomplete judgments, rank fusion, answer support, and scenario-clustered resampling.
- The corpus was selected using meeting summaries and transcripts, and queries were generated with transcript context. This favors transcript retrieval and is not a new held-out query set. The 100 previously unjudged windows do not constitute comprehensive hard negatives. Larger libraries and unseen meetings may change the ordering.
- Review assessed transcript relevance, not audio listening or acoustic fidelity (whether the signal preserves audible content and speaking characteristics). Recognition errors and clipped context remain. All relevance dimensions and pairwise judgments use the same assistant; there is no independent human or second-model adjudication.
- Private data and complete per-query results remain in ignored local storage. Repository tests and documentation contain synthetic examples and aggregate results only. Inference did not upload recordings or transcripts, and no app integration was changed.

# Recommended next step

For direct audio topic search, advance Jina to a held-out test and native-feasibility investigation if its usage rights fit the app. Preserve CLSP only for its separate speaking-style use case unless a style-specific evaluation establishes value. For meetings with transcripts, prioritize multilingual transcript embeddings; Jina is the quality target from this run, while unrestricted alternatives need their own comparison before a shipping choice.

Keep BM25 and character search as measured baselines. Test language-aware candidate combination and reranking on separate development queries, then evaluate once on held-out queries. This run does not justify selecting fusion weights or a routing rule on the same 50 queries. Add independent listening and relevance review, more confusable passages, and a larger unseen library before replacing production retrieval.
