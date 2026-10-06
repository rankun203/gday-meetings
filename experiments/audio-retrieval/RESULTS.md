---
title: Audio and transcript retrieval comparison
date: 2026-10-06
status: evaluated-with-limits
scope: local-retrieval-model-selection
---

# Findings

**The expanded run separates Jina and Granite, but does not reproduce the synthetic decision-failure pattern.** All methods now search 1,677 windows for 102 queries. Jina transcript achieves 69.6% evidence hit @1 versus Granite 311M's 63.7%; useful first results are 90.2% versus 83.3%. Both reach 65.7% automated full support @1. The paired meeting-cluster interval for Granite minus Jina's evidence hit is −12.9 to +1.0 percentage points, so this development set does not establish a stable population advantage.

**Granite's largest deficit is on short, reviewed spans, not the new decision/status challenge.** Reviewed-span hit @1 is 18.8% for Granite and 34.4% for Jina. On the 20 decision/status queries, Granite gets 18 labeled first hits and Jina 17; both return useful first passages for all 20. That challenge covers only ten bilingual facts. The earlier synthetic 70.8% versus 100% result remains motivation, not a result transferable to these recordings.

**Qwen3 0.6B is a strong permissively licensed candidate; transcript errors still constrain all three.** Qwen matches Jina's 69.6% overall evidence hit and 90.2% useful first results, with 69.6% full support. Its measured text inference and loaded memory are higher than Granite's. Applying the user's local corrections raises reviewed-span hit @1 to 62.5% for Jina, 46.9% for Granite and 59.4% for Qwen. These targeted patches diagnose recoverable transcript loss; they are not complete gold transcripts or an independent test set.

**The tested audio fusion hurts spoken-content retrieval.** Jina audio reaches 21.6% evidence hit @1; fixed Jina audio + transcript fusion reaches 37.3%, below transcript alone. It does not recover a labeled first result for any of the 32 reviewed-span queries under any transcript condition. This run gives no evidence for retaining that fusion as a fallback for missing words. Acoustic-style and non-speech search remain separate, untested use cases.

# References

**Retrieving sound versus spoken content.** [Yang et al.'s CLSP paper](https://arxiv.org/abs/2601.03065) studies contrastive language–speech representations for properties such as speaking style. [Wu et al.'s CLAP paper](https://arxiv.org/abs/2211.06687) aligns general audio with textual descriptions. Contrastive training brings matched examples closer in representation space and separates mismatches. These objectives motivate audio baselines, but neither establishes that a model can recover detailed meeting facts. [Hönicke et al.'s Jina omni paper](https://arxiv.org/abs/2605.08384) connects audio and visual encoders to a shared text embedding space, motivating the paired audio/transcript comparison.

**Multilingual transcript retrieval.** The [multilingual E5 report](https://arxiv.org/abs/2402.05672) provides a compact text baseline. The [Granite Multilingual R2 report](https://arxiv.org/abs/2605.13521), [Harrier model card](https://huggingface.co/microsoft/harrier-oss-v1-270m), and [Qwen3 Embedding report](https://arxiv.org/abs/2506.05176) motivate the English/Chinese shortlist at different model sizes. Published benchmark performance informs selection, but is not included as a measurement on this corpus.

**Ranking and evaluation.** *Introduction to Information Retrieval* explains [BM25 term matching](https://nlp.stanford.edu/IR-book/html/htmledition/okapi-bm25-a-non-binary-model-1.html) and [ranked-retrieval evaluation](https://nlp.stanford.edu/IR-book/html/htmledition/evaluation-of-ranked-retrieval-results-1.html). [Cormack, Clarke and Buettcher](https://plg.uwaterloo.ca/~gvcormac/cormacksigir09-rrf.pdf) combine rankings through reciprocal rank fusion. Together these motivate lexical controls, fixed fusion ablations, and separate measures for recovering a labeled discussion, ranking useful evidence, and supporting an answer.

**Preparing a reference from audio.** The [OpenAI transcription guide](https://developers.openai.com/api/docs/guides/realtime-transcription) describes [GPT-Live-Transcribe](https://developers.openai.com/api/docs/models/gpt-live-transcribe), including committed audio turns and the absence of word timestamps. It supports drafting text to compare with Apple's output; it does not establish ground truth. Listening review, rather than agreement between recognizers, determines whether disputed content was actually spoken.

# Experiment setup

## Question and dataset

The experiment asks whether commercially usable transcript encoders can match Jina on recorded meetings, especially when the requested evidence is a changed setting, an alternative, or a still-undecided proposal. An earlier synthetic-script result motivated that question but is excluded from the measurements below. All audio here comes from recorded meetings. GPT helps draft references and assess retrieved text; it is not evaluated as an app transcription provider.

Every method searches the same **1,677 windows for 102 queries**. A window is a bounded audio interval; its passage is the text indexed for that interval. A query is a written request to locate discussion or evidence. The gallery spans 49 meetings; queries target 27. There are 51 English and 51 Chinese queries, including 40 cross-language queries whose language differs from the target meeting's metadata. These language labels do not capture every instance of code-switching.

| Query group | Queries | Evidence and purpose |
| --- | ---: | --- |
| Original | 50 | Historical transcript-grounded labels; rerun against the larger gallery |
| Reviewed spans | 32 | English/Chinese versions of 16 facts or local contexts supported by the user's annotations |
| Decision/status challenge | 20 | English/Chinese versions of 10 transcript-grounded distinctions involving changes, alternatives or provisional decisions |

The gallery contains 1,500 historical windows from 40 meetings, selected with a fixed SHA-256 ordering. Original windows, labeled answers and explicitly declared competing passages are retained before filling the remaining slots. Another 177 windows come from the ten five-minute review excerpts and the quiet-room follow-up. Query wording, labels and declared alternatives were written before inspecting the expanded encoder rankings. Related queries share a meeting cluster; the 52 new queries are 26 bilingual facts, not 52 independent events. This is a development evaluation, not a held-out population sample.

The reviewed excerpts cover six Chinese remote calls, three English remote calls and one noisy, low-voice English room recording. The main gallery uses one source track per new excerpt: system audio for remote calls and microphone audio for the room. Fresh Apple text from that track is indexed for the 177 new windows; the other 1,500 retain imported text. Thus **Transcript** in the main matrix means this explicit mixed corpus, held identical across encoders. It does not mean every historical passage came from Apple or a known WhisperX version. The historical source of most transcripts is unknown; the retained metadata for the room recording names `large-v2`, without a complete runtime configuration.

Audio is mono 16 kHz PCM for retrieval, with windows no longer than 30 seconds. New windows use 20-second boundaries, including a shorter final window when necessary. Their source recognition runs use mono 24 kHz PCM without gain normalization, denoising or synthetic noise. Total candidate audio is 38,441.338 seconds, or 10.68 hours of window duration, including overlapping intervals. Four silent audio windows and 21 empty indexed passages remain candidates. Format, duration, sample finiteness and fingerprints were checked; these checks do not establish that every original source stream is complete.

## Reference preparation and transcript inputs

The user supplied ten first-pass annotations and one review of a later quiet-room interval. Those yield 23 explicit corrected spans plus a broadly endorsed Apple draft with unspecified small remaining errors. Context-only identity knowledge is excluded from audio-backed corrections. Ellipses remain gaps, and a preference for one recognizer does not verify every word. The reviewed-span queries use supported content; they do not turn complete five-minute drafts into gold transcripts. Other query groups remain grounded in historical text rather than independently verified audio.

The room follow-up includes twelve quiet 40-second windows selected using low signal level and sparse imported transcript timestamps, followed by a user-selected 95-second interval. One overlapping 40-second scan window is excluded from the expanded gallery, leaving 535 unique seconds of follow-up audio. Low signal level is not speech detection. Original and amplified listening copies are kept privately; amplification was never fed to the recognizers. The complete source annotations are preserved unchanged, with hashes and separate curated interpretations.

**Apple** uses SpeechTranscriber's finalized `timeIndexedProgressiveTranscription` output, replayed in accelerated 100 ms packets with English or Chinese locale. It exercises the live recognizer's preset on recorded input; it does not measure live latency or reconstruct the historical session. The original reference review compared both tracks when available, but this controlled retrieval run uses the selected track only; a production app indexing both tracks may recover additional words.

**WhisperX** is rerun on the same 22 selected source excerpts with [`faster-whisper-large-v2` at `f0fe815`](https://huggingface.co/Systran/faster-whisper-large-v2/tree/f0fe81560cb8b68660e564f55dd99207059c092e), CPU/int8, batch size one, four recognition threads, explicit transcription task and known language, followed by word alignment. This is a controlled local run, not a measurement of the Runpod worker's GPU/float16 execution. Chinese text receives the worker's OpenCC `tw2sp` conversion. Timestamped words are assigned by midpoint; incomplete word alignment falls back to assigning a whole segment by midpoint. Fixed windows and alignment can split useful context.

**GPT draft references** use `gpt-live-transcribe` with requested high delay, no transcript/name hints, no noise reduction and explicit 20-second commits. The service accepts the delay request but does not echo it. These drafts help identify discrepancies and do not enter the main retrieval corpus. Agreement is not independently verified speech. No GPT recognition accuracy ranking is reported.

The paired transcription ablation changes only the 177 new passages, leaving all 1,500 historical passages, queries, labels and audio fixed. It compares Apple, fresh WhisperX, imported text and **review-patched Apple** for Jina, Granite 311M and Qwen. The patched condition applies 19 exact substitutions across ten windows, justified by the annotations; remaining draft wording stays unverified. It is a diagnostic of transcript sensitivity, not an oracle reference or a word-error-rate evaluation. The earlier two leading models motivated this ablation; Qwen was included as another candidate after the expanded text run, so this is exploratory model selection.

## Retrieval methods

An **embedding** is a numerical representation. Vectors are normalized to unit length, so their dot product is cosine similarity. Every dense method scores every candidate directly; there is no approximate index, reranker, query translation or generated summary. Pooling combines token or chunk representations into a vector. The hardware is an Apple M1 Max with 64 GiB unified memory, running macOS 26.6.2. The frozen checkpoints are:

| Encoder | Pinned checkpoint | Candidate input | Vector construction | Dimensions |
| --- | --- | --- | --- | ---: |
| CLSP | [yfyeung/CLSP · 30355ce](https://huggingface.co/yfyeung/CLSP/tree/30355ce67960e4cc1562e4e5fa154baf86a21430) | Audio | Whole-window encoder | 512 |
| CLAP | [LAION HTSAT unfused · 8fa0f1c](https://huggingface.co/laion/clap-htsat-unfused/tree/8fa0f1c6d0433df6e97c127f64b2a1d6c0dcda8a) | Audio | Maximum chunk similarity or mean chunk embedding | 512 |
| Jina | [v5 omni nano retrieval · b7287f6](https://huggingface.co/jinaai/jina-embeddings-v5-omni-nano-retrieval/tree/b7287f6b6b562e25bc4a28b939d1f936484b4137) | Audio or transcript, separately | Last valid token | 768 |
| Multilingual E5 small | [614241f](https://huggingface.co/intfloat/multilingual-e5-small/tree/614241f622f53c4eeff9890bdc4f31cfecc418b3) | Transcript | Mean of non-padding tokens | 384 |
| Granite 97M | [Multilingual R2 · 835ad14](https://huggingface.co/ibm-granite/granite-embedding-97m-multilingual-r2/tree/835ad14087e140460703cf0fae09f97d469d65c2) | Transcript | First special token (CLS) | 384 |
| Granite 311M | [Multilingual R2 · 4439955](https://huggingface.co/ibm-granite/granite-embedding-311m-multilingual-r2/tree/44399559930365213510b1ee2eb15ded83374f0e) | Transcript | CLS | 768 |
| Harrier 270M | [OSS v1 · 31de22b](https://huggingface.co/microsoft/harrier-oss-v1-270m/tree/31de22b673913c7d658c0f03f792d77c2dcf8ebd) | Transcript | Last non-padding token | 640 |
| Harrier 0.6B | [OSS v1 · f9b9dc8](https://huggingface.co/microsoft/harrier-oss-v1-0.6b/tree/f9b9dc8d367d443f2479d27aa5d8d2850c0774ee) | Transcript | Last non-padding token | 1,024 |
| Qwen3 0.6B | [Embedding · 97b0c61](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B/tree/97b0c614be4d77ee51c0cef4e5f07c00f9eb65b3) | Transcript | Last non-padding token | 1,024 |

The pinned Granite, Qwen and CLAP checkpoints declare Apache 2.0; Harrier and E5 declare MIT. Jina declares CC BY-NC 4.0 and serves as a research reference. No Core ML or reduced-precision distribution artifact was created.

CLSP encodes whole windows; its original CPU filterbank is retained while encoder inference uses Metal. CLAP resamples to 48 kHz and covers each window with consecutive chunks of at most ten seconds, evaluated using maximum chunk similarity and normalized mean chunk embeddings. Jina separately embeds audio and text using its published pooling, prefixes and real-frame masks. E5 uses `query:`/`passage:` prefixes and masked mean pooling. Granite uses CLS pooling without prefixes. Harrier and Qwen use last-token pooling and one fixed meeting-retrieval instruction on queries. Encoder inference uses float32 and batch size one on Metal. The main environment uses PyTorch 2.14.1 and Transformers 5.18.0; CLSP uses Torch 2.8.0 and Transformers 4.57.3 for checkpoint compatibility. E5's maximum input is 228 tokens, below its 512-token limit; the other text candidates reject overlength input rather than silently truncate.

**Lexical retrieval** includes BM25 (`k1=1.2`, `b=0.75`), word TF-IDF and character TF-IDF. The multilingual tokenizer uses lowercased Latin words/numbers and Chinese characters plus adjacent pairs. Word TF-IDF adds adjacent term pairs; character TF-IDF uses two-to-four-character sequences. Both use sublinear term frequency and fit only candidate text. Zero-score lexical matches return no result. Ties use a fixed hash of the candidate ID.

**Fusion** uses equal-weight reciprocal rank fusion: add `1 / (60 + rank)` across rankings, starting rank at one. Dense rankings include every candidate; lexical rankings exclude zero matches. The tested pairs are E5 + BM25, Jina transcript + BM25, Jina audio + BM25, and Jina audio + Jina transcript. No weights or thresholds were tuned on these results. Jina's text-only loading path reproduces all 1,779 full-model query/text vectors exactly, so it is one accuracy method with a separate resource measurement.

## Metrics, judgments and uncertainty

**Evidence hit @k** is the fraction of queries retrieving at least one labeled window in the first k results. Labels are nonexhaustive; a miss can still be useful. **Recall @k** averages the fraction of labeled positives recovered; unlike the original corpus, some new queries have multiple positives. **MRR** averages the reciprocal rank of the first positive over the full ranking. Evidence metrics locate labeled intervals; they do not prove that the indexed ASR retained the requested fact.

**Useful @1** counts a first result graded 2 or 3 on a scale from 0 (unrelated/misleading), through 1 (topic only) and 2 (useful partial evidence), to 3 (direct requested discussion/details). **Full support @1** requires the requested reference-backed facts in the returned passage. A general rule lacking a requested changed detail is partial support. Discussion-finding queries do not necessarily require a final decision. Other support classes are partial, question-only, absent and contradiction. No generated answer is evaluated.

The shared pool contains each method's top five, labeled positives and one deterministic random control per query, deduplicated by pair. 4,699 pairs receive GPT-5.6 Luna judgments with medium reasoning and method identities/ranks hidden. Fixed reference evidence is supplied, but positive window IDs are not. The query-only preliminary rubric was superseded after it overcredited a general rule lacking a revised detail; none of those preliminary grades enters this report. Structured output requires every short record key, locally mapped to immutable review IDs. These are automated, reference-conditioned text judgments, not independent human or audio verification. Audio methods' graded metrics assess the indexed text at the returned window and can therefore underrate information audible only in the recording.

**Pooled nDCG @5** discounts ranked gains `2^grade − 1` by `log2(rank + 1)` and normalizes against the best five grades in the shared pool. It is not exhaustive-corpus nDCG. Useful precision @5 counts useful passages in five slots. Missing slots count as zero. **Paired intervals** resample whole meeting clusters, retaining related queries and translations, with 10,000 bootstrap draws and seed 42. The 95% percentile intervals are exploratory and unadjusted for multiple comparisons. Differences are percentage points (pp), not relative percentages.

# Results

## Comparison matrix

All rows use the expanded 102-query, 1,677-window corpus and the same graded pool. The previous 50-query/150-window matrices are superseded rather than mixed into these results.

| Input | Method | Evidence @1 | @5 | @10 | MRR | Useful @1 | Full support @1 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Audio | CLSP | 0.0% | 0.0% | 0.0% | 0.004 | 0.0% | 0.0% |
| Audio | CLAP · maximum | 0.0% | 0.0% | 0.0% | 0.002 | 0.0% | 0.0% |
| Audio | CLAP · mean | 0.0% | 0.0% | 0.0% | 0.002 | 1.0% | 0.0% |
| Audio | Jina | 21.6% | 34.3% | 39.2% | 0.276 | 36.3% | 22.5% |
| Transcript | BM25 | 42.2% | 53.9% | 55.9% | 0.479 | 52.9% | 40.2% |
| Transcript | Word TF-IDF | 34.3% | 52.9% | 57.8% | 0.431 | 45.1% | 33.3% |
| Transcript | Character TF-IDF | 35.3% | 55.9% | 59.8% | 0.447 | 46.1% | 35.3% |
| Transcript | E5 small | 43.1% | 57.8% | 60.8% | 0.499 | 60.8% | 44.1% |
| Transcript | Jina | 69.6% | 87.3% | 90.2% | 0.776 | 90.2% | 65.7% |
| Transcript | Granite 97M | 56.9% | 75.5% | 80.4% | 0.651 | 80.4% | 57.8% |
| Transcript | Granite 311M | 63.7% | 81.4% | 85.3% | 0.718 | 83.3% | 65.7% |
| Transcript | Harrier 270M | 51.0% | 70.6% | 73.5% | 0.602 | 78.4% | 52.9% |
| Transcript | Harrier 0.6B | 56.9% | 78.4% | 80.4% | 0.667 | 81.4% | 59.8% |
| Transcript | Qwen3 0.6B | 69.6% | 85.3% | 86.3% | 0.774 | 90.2% | 69.6% |
| Transcript | E5 + BM25 | 48.0% | 58.8% | 59.8% | 0.530 | 60.8% | 46.1% |
| Transcript | Jina + BM25 | 52.0% | 62.7% | 65.7% | 0.583 | 66.7% | 52.0% |
| Audio + transcript | Jina audio + BM25 | 30.4% | 47.1% | 57.8% | 0.394 | 46.1% | 34.3% |
| Audio + transcript | Jina audio + Jina transcript | 37.3% | 54.9% | 64.7% | 0.458 | 57.8% | 41.2% |

Qwen and Jina tie on labeled first hits but do not have identical rankings. Granite remains competitive on longer historical discussions and the selected decision/status distinctions; its weaker reviewed-span results lower the overall score. A labeled timestamp hit and a passage supporting the requested fact are different outcomes. The graded columns are automated estimates, with the limitations stated below.

## Jina and Granite: the motivating question

| Query group | Method | Evidence @1 | Useful @1 | Full support @1 |
| --- | --- | --- | --- | --- |
| All · 102 | Jina | 69.6% | 90.2% | 65.7% |
| All · 102 | Granite 311M | 63.7% | 83.3% | 65.7% |
| All · 102 | Qwen3 0.6B | 69.6% | 90.2% | 69.6% |
| Original · 50 | Jina | 86.0% | 98.0% | 84.0% |
| Original · 50 | Granite 311M | 82.0% | 94.0% | 82.0% |
| Original · 50 | Qwen3 0.6B | 82.0% | 96.0% | 82.0% |
| Reviewed spans · 32 | Jina | 34.4% | 71.9% | 25.0% |
| Reviewed spans · 32 | Granite 311M | 18.8% | 56.2% | 25.0% |
| Reviewed spans · 32 | Qwen3 0.6B | 37.5% | 75.0% | 37.5% |
| Decision/status · 20 | Jina | 85.0% | 100.0% | 85.0% |
| Decision/status · 20 | Granite 311M | 90.0% | 100.0% | 90.0% |
| Decision/status · 20 | Qwen3 0.6B | 90.0% | 100.0% | 90.0% |

Granite minus Jina, in percentage points. Intervals include meeting-level uncertainty, not judge or annotation uncertainty.

| Query group | Metric | Difference (pp) | 95% interval (pp) | Meetings |
| --- | --- | --- | --- | --- |
| All | Evidence @1 | -5.9 | -12.9 to +1.0 | 27 |
| All | Useful @1 | -6.9 | -15.1 to +1.1 | 27 |
| All | Full support @1 | +0.0 | -4.8 to +4.8 | 27 |
| Reviewed spans | Evidence @1 | -15.6 | -29.4 to +0.0 | 9 |
| Reviewed spans | Useful @1 | -15.6 | -34.4 to +10.0 | 9 |
| Reviewed spans | Full support @1 | +0.0 | -9.4 to +7.9 | 9 |
| Decision/status | Evidence @1 | +5.0 | +0.0 to +16.7 | 9 |
| Decision/status | Useful @1 | +0.0 | +0.0 to +0.0 | 9 |
| Decision/status | Full support @1 | +5.0 | +0.0 to +16.7 | 9 |

Jina and Granite return the same first window for 73 of 102 queries. Both hit a label on 62 queries; Jina alone hits on nine, Granite alone on three, and neither on 28. In the decision/status cohort, their first results agree on 19 of 20 queries. The close agreement there does not support a general claim that Granite retrieves obsolete proposals on recorded meetings.

Inspection covered all ten decision/status facts and the two encoders' first-result disagreements. One changed-setting request makes both retrieve a general timing rule that omits the revised detail: useful partial evidence, not a confirmed answer. Another historical query makes Jina retrieve the question while Granite retrieves the passage containing its answer. Elsewhere, Granite returns broad background where Jina supplies the requested technical detail, or unrelated numeric discussion where Jina finds the relevant number. These are distinct failures; chronology cannot be inferred from a label miss alone.

Short, generic requests can retrieve another valid discussion elsewhere in the library. A muting query is one such case: Granite misses the nominated window but returns a useful muting exchange. Conversely, locating a labeled window whose ASR has corrupted a term or quantity does not restore that fact. Reviewed-span full support is only 25.0% for both Jina and Granite on the main Apple condition, despite different timestamp-hit rates. Missing recognition, ambiguous requests, split context and encoder ranking all contribute.

## Transcript and fusion ablations

Each condition supplies text for the same 177 new windows. Evidence @1 is shown for all 102 queries and for the 32 reviewed-span queries; the graded columns use only those 32. The separate first-result pool contains 243 deduplicated pairs, reusing identical main-pool judgments and grading changed passages with the same fixed references.

| New passage source | Method | All evidence @1 | Reviewed evidence @1 | Reviewed useful @1 | Reviewed full support @1 |
| --- | --- | --- | --- | --- | --- |
| Apple | Jina | 69.6% | 34.4% | 71.9% | 25.0% |
| Apple | Granite 311M | 63.7% | 18.8% | 56.2% | 25.0% |
| Apple | Qwen3 0.6B | 69.6% | 37.5% | 75.0% | 37.5% |
| Apple | BM25 | 42.2% | 15.6% | 34.4% | 12.5% |
| Apple | Jina audio + transcript | 37.3% | 0.0% | 25.0% | 12.5% |
| Imported | Jina | 65.7% | 21.9% | 62.5% | 31.2% |
| Imported | Granite 311M | 61.8% | 12.5% | 46.9% | 34.4% |
| Imported | Qwen3 0.6B | 65.7% | 25.0% | 65.6% | 34.4% |
| Imported | BM25 | 44.1% | 21.9% | 37.5% | 18.8% |
| Imported | Jina audio + transcript | 37.3% | 0.0% | 25.0% | 9.4% |
| WhisperX | Jina | 64.7% | 18.8% | 65.6% | 18.8% |
| WhisperX | Granite 311M | 62.7% | 15.6% | 43.8% | 18.8% |
| WhisperX | Qwen3 0.6B | 68.6% | 34.4% | 75.0% | 34.4% |
| WhisperX | BM25 | 42.2% | 15.6% | 34.4% | 6.2% |
| WhisperX | Jina audio + transcript | 37.3% | 0.0% | 25.0% | 9.4% |
| Review-patched Apple | Jina | 78.4% | 62.5% | 81.2% | 65.6% |
| Review-patched Apple | Granite 311M | 72.5% | 46.9% | 65.6% | 50.0% |
| Review-patched Apple | Qwen3 0.6B | 76.5% | 59.4% | 90.6% | 65.6% |
| Review-patched Apple | BM25 | 48.0% | 34.4% | 46.9% | 34.4% |
| Review-patched Apple | Jina audio + transcript | 37.3% | 0.0% | 25.0% | 12.5% |

The local patches add nine reviewed-span first hits each for Jina and Granite, and seven for Qwen. Full support rises from 25.0% to 65.6% for Jina, from 25.0% to 50.0% for Granite, and from 37.5% to 65.6% for Qwen. Thus correcting text helps all three while leaving a meaningful residual ranking problem. Because the patches repair the same annotated facts queried here, this is a targeted sensitivity test, not an unbiased forecast of future correction gains.

Fresh WhisperX does not improve the selected reviewed-span group overall: evidence hit @1 is 18.8% for Jina, 15.6% for Granite and 34.4% for Qwen. Imported text sometimes preserves a requested phrase better than either fresh recognizer. Empty new windows number 21 with Apple, 33 with imported text, 24 with WhisperX and 21 after local Apple patches. These counts describe available indexed text, not silence detection or general recognition quality.

The quiet-room result is mixed and especially limited. Fresh WhisperX still omits a central passage present in the broadly endorsed Apple draft. For the one explicitly corrected phrase used as a bilingual retrieval fact, imported text gives all three encoders a labeled first hit in both languages. Unpatched Apple and fresh WhisperX give none. Patching Apple lets Jina hit first in both languages, Qwen in one, and Granite in neither. This tests one phrase near the end of the reviewed interval; the missing central discussion lacks a complete verbatim reference and is not a separately scored retrieval fact. It cannot establish which recognizer handles quiet meetings generally.

The fixed audio + transcript fusion remains at 0/32 labeled first hits through all four conditions, even when transcript-only retrieval improves. Its constant, equal weights were not optimized. A different fusion or confidence-based fallback would require a separately defined evaluation; these results do not establish that audio can never help.

## Language coverage and ranked usefulness

Cells show evidence @1 / full support @1. These groups have different topics and difficulty; differences do not isolate language ability.

| Method | English · 51 | Chinese · 51 | Same language · 62 | Cross-language · 40 |
| --- | --- | --- | --- | --- |
| Jina | 70.6% / 68.6% | 68.6% / 62.7% | 71.0% / 64.5% | 67.5% / 67.5% |
| Granite 311M | 64.7% / 70.6% | 62.7% / 60.8% | 67.7% / 66.1% | 57.5% / 65.0% |
| Qwen3 0.6B | 70.6% / 72.5% | 68.6% / 66.7% | 69.4% / 67.7% | 70.0% / 72.5% |
| Granite 97M | 58.8% / 60.8% | 54.9% / 54.9% | 58.1% / 56.5% | 55.0% / 60.0% |
| Harrier 270M | 47.1% / 56.9% | 54.9% / 49.0% | 62.9% / 59.7% | 32.5% / 42.5% |
| Harrier 0.6B | 56.9% / 58.8% | 56.9% / 60.8% | 61.3% / 62.9% | 50.0% / 55.0% |
| E5 small | 43.1% / 47.1% | 43.1% / 41.2% | 64.5% / 64.5% | 10.0% / 12.5% |
| Jina audio | 23.5% / 23.5% | 19.6% / 21.6% | 22.6% / 24.2% | 20.0% / 20.0% |

| Method | Pooled nDCG @5 | Useful precision @5 | Labeled recall @5 | Any full support @5 |
| --- | --- | --- | --- | --- |
| Jina | 0.783 | 51.8% | 86.8% | 80.4% |
| Granite 311M | 0.708 | 45.7% | 81.4% | 76.5% |
| Qwen3 0.6B | 0.761 | 50.0% | 85.3% | 80.4% |
| Granite 97M | 0.656 | 42.0% | 74.5% | 75.5% |
| Harrier 270M | 0.623 | 39.0% | 70.6% | 68.6% |
| Harrier 0.6B | 0.688 | 45.7% | 78.4% | 74.5% |
| E5 small | 0.502 | 29.6% | 57.8% | 53.9% |
| Jina audio | 0.340 | 19.0% | 33.3% | 39.2% |
| Jina audio + transcript | 0.556 | 35.3% | 53.4% | 63.7% |

## Resource observations

Per-item median / p95 milliseconds. Query and transcript counts are 102 and 1,677 respectively; each audio encoder covers all 1,677 windows. CLAP timing includes all chunks of a window. CLSP timing includes CPU filterbank extraction.

| Encoder process | Query (ms) | Transcript (ms) | Audio window (ms) |
| --- | --- | --- | --- |
| Jina text only | 14.8 / 21.5 | 21.3 / 31.0 | — |
| Granite 97M | 14.2 / 23.1 | 17.8 / 31.6 | — |
| Granite 311M | 18.2 / 28.2 | 21.9 / 32.2 | — |
| Harrier 270M | 24.9 / 35.3 | 28.3 / 44.4 | — |
| Harrier 0.6B | 38.5 / 51.1 | 43.9 / 59.3 | — |
| Qwen3 0.6B | 36.7 / 45.4 | 48.5 / 68.6 | — |
| E5 small | 11.7 / 16.6 | 12.3 / 16.8 | — |
| Jina full | 16.7 / 23.6 | 19.8 / 29.4 | 674.7 / 839.3 |
| CLAP | 26.9 / 213.1 | — | 102.1 / 128.2 |
| CLSP | 33.7 / 222.1 | — | 463.0 / 2322.4 |

Memory sampling is available for the six text-only processes. Values use decimal MB/GB; other runners did not collect comparable peak-memory data.

| Text process | Checkpoint MB | Loaded parameters GB | Peak RSS GB | Sampled Metal driver GB | Load seconds |
| --- | --- | --- | --- | --- | --- |
| Jina text only | 1895 | 0.85 | 3.61 | 1.47 | 1.38 |
| Granite 97M | 195 | 0.39 | 1.23 | 1.35 | 1.53 |
| Granite 311M | 623 | 1.25 | 2.96 | 1.63 | 1.96 |
| Harrier 270M | 536 | 1.07 | 2.60 | 1.34 | 1.60 |
| Harrier 0.6B | 1192 | 2.38 | 4.59 | 2.85 | 1.35 |
| Qwen3 0.6B | 1192 | 2.38 | 4.59 | 2.85 | 0.92 |

Timing is observed Python inference on the recorded hardware, not app latency. Primary encoder processes run sequentially, but local WhisperX recognition and brief CPU parity probes overlap part of the run. The final CLSP run also overlaps the separate transcript-variant GPU runs; its timing is especially unsuitable for a controlled speed comparison. Other system activity is uncontrolled. Shape initialization, file I/O and background work affect tails. Do not treat small differences as stable deployment advantages. RSS and Metal memory overlap on unified memory and must not be added. Ten-millisecond memory sampling can miss peaks. Checkpoint size differs from loaded float32 parameter memory; Jina's downloaded checkpoint includes components omitted from text-only loading. ASR, energy, native conversion, quantization and simultaneous app recording are not included in these resource comparisons.

# Validation and limitations

All ten primary encoder processes and nine paired transcript-variant processes completed on their frozen inputs. Comparison verifies corpus/audio fingerprints, dimensions, finite scores and complete judgment coverage. The 918 variant query vectors agree with their unchanged main-run counterparts within 0.000001 maximum component error. Jina's 1,779 full-model query/text vectors are bitwise identical to its text-only path. Twelve new Jina/Granite CPU–Metal query/document checks and six CLSP probe checks also agree within 0.000001; these are numerical parity checks, not native deployment validation.

Ten retrieval metric tests, six expansion/support tests and eleven reference-review tests pass. Source annotations remain byte-identical to the saved originals. No synthetic speech contributes to these matrices. Formatting, document links and privacy checks cover the changed experiment files.

This corpus is intentionally enriched with difficult corrections, exact terms and competing passages. Human review selections are not representative ASR samples, and bilingual variants are correlated. Some short queries are ambiguous across meetings. Historical references can be wrong; even the human-supported group does not provide complete verbatim transcripts. The decision/status challenge covers ten facts across selected meetings, not a general guarantee of temporal reasoning or final-decision tracking. All queries have positives, so abstention and absent-answer behavior remain untested.

The larger gallery tests more distractors, not unseen-query generalization. Automated grading depends on imperfect reference evidence and a single judge family. A useful transcript can disagree with a nonexhaustive timestamp label; a correctly retrieved timestamp can contain an incorrect recognized fact. Neither is resolved by quoting one aggregate accuracy number. Inspection also found debatable automated grades for broad queries and acoustic details such as a spoken pause. The same passage sometimes receives different support grades for bilingual paraphrases. The judged percentages are diagnostic estimates, not adjudicated accuracy or proof of model equivalence. Source decoding emitted some demux warnings; output format, duration and sample checks do not prove every input stream was intact. The source recordings and service receipts remain available for audit.

The CLSP checkpoint needs a compatible older Transformers runtime and emits legacy AMP decorator warnings. WhisperX alignment emits a deprecated gradient-checkpointing configuration warning; training is disabled. Its optional TorchCodec decoder cannot load the installed FFmpeg libraries; the runner supplies predecoded arrays, so that decoder is not used. These warnings are recorded, not suppressed. Replacing those dependencies requires parity validation rather than silently altering the frozen implementations. No app, Keychain entry, meeting file or provider setting is modified by the experiment.

Keep Qwen3 0.6B and Granite 311M as the deployment shortlist: Qwen for the stronger measured retrieval quality, Granite for its smaller checkpoint and lower observed inference cost. Before selecting either, evaluate unseen meetings with independently checked answers and absent-answer queries, then measure native conversion, energy and recording-time contention. The present results justify that shortlist, not production equivalence with Jina.

Reproduction uses [the expanded procedure](expanded/README.md), [encoder requirements](requirements.txt), [the retrieval runner](expanded/run.py), [comparison](compare.py), [reference-conditioned review](expanded/judge.py), and [paired transcript scoring](expanded/score_variants.py). Private inputs, frozen queries, audio hashes, embeddings, full rankings, raw judge responses and failure-review material are retained in ignored `tmp/audio-retrieval-expanded-2026-10-06/`. Source annotations remain in their original review packages, unchanged. Public reports contain aggregates and anonymous method descriptions only.
