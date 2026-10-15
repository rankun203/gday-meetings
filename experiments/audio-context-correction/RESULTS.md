---
title: Contextual audio correction results
date: 2026-10-14
status: exploratory
---

# Findings

Using a broad meeting roster and general environment vocabulary, audio review recovered the English person-name target in both prompt conditions. It did not recover the other person-name pair. Revision partly repaired an environment phrase but used a related shorter English form instead of the supplied evaluation target. Independent transcription of that clip returned empty text.

The realistic roster condition is the primary result. Earlier selectively chosen vocabulary runs are superseded exploratory diagnostics. No request told the model which specific word was wrong or supplied the expected corrected sentence. Nevertheless, earlier vocabulary was selected from known errors, so those results were biased toward the targets.

The realistic run supports further evaluation, not automatic transcript replacement. Existing errors sometimes survived revision. An HTTP 200 response can still be empty, and plausible proposed changes have not been independently verified against the audio.

# References

- [OpenAI audio in Chat Completions](https://developers.openai.com/api/docs/guides/audio-chat-completions) documents audio input with text instructions, the tested correction mechanism.
- [GPT-Audio-1.5](https://developers.openai.com/api/docs/models/gpt-audio-1.5) documents the model used for the realistic run.
- [GPT-Audio](https://developers.openai.com/api/docs/models/gpt-audio) documents the older model family. An older dated snapshot was used only in the initial diagnostic run; it is not the recommended/default implementation.

These references establish API capability, not recognition accuracy on bilingual meetings. No external benchmark establishes the correction quality reported here.

# Experiment Setup

Five manually selected clips came from one authorized Mandarin meeting with English terms: three known error passages, a short acknowledgment, and an adjacent substantive passage without a supplied correction. Total distinct audio was 102.30 seconds. The system-audio track was read without changing the recording or transcript. Each clip covers a saved transcript segment with 0.3 seconds of padding on each side.

**Context transcription** receives audio plus context. **Bounded revision** additionally receives the existing inaccurate transcript and instructions to correct recognition errors only. Both prompts request verbatim bilingual wording, preserve repetitions, and permit an unclear marker.

The primary context contains the same user-provided broad roster with natural surname/given-name fields and roles, two meeting bots, and five common environment names for every clip. It contains no target-specific name list, derived phonetic spellings, target acronym glossary, expected corrections, or timestamp clues. Clip identifiers are neutral. Expected corrections were used only for evaluation. Exact request text is retained in ignored private prompt files.

The primary run uses `gpt-audio-1.5`, temperature 0, text-only output, `store: false`, and a maximum of 1,800 output tokens. Requests are sequential. Ten requests yielded ten HTTP 200 responses, including one empty result. Earlier selective-vocabulary runs used `gpt-audio-1.5` and `gpt-audio-2025-08-28` with the same two conditions; those yielded twenty HTTP 200 responses plus one initial HTTP 500, retried once.

**Target recovery** distinguishes exact canonical spelling from related phonetic or semantic wording; it is not whole-transcript accuracy. **Latency** is client request elapsed time, excluding extraction and audio accumulation. **Control drift** describes changes to unmarked passages without assuming their original text is correct.

# Results

## Primary realistic roster comparison

| Target category | Context transcription | Bounded revision |
| --- | --- | --- |
| English person name | Exact target recovered | Exact target recovered |
| Two romanized Chinese names | First name remains wrong; second Chinese rendering is phonetically plausible | Original erroneous pair retained |
| Environment term | Empty output | Partial repair; shorter English form instead of exact target; surrounding errors retained |

The Chinese-name evaluation does not invent character ground truth: the user supplied romanized names. Correct characters cannot be inferred solely from audio. The output failed to identify the first name in the pair even at the phonetic level.

The acknowledgment control was preserved, apart from punctuation and a JSON wrapper in independent transcription. The substantive control proposed English technical words missing from the original. These may be useful corrections but were not independently verified. Independent transcription also changed surrounding wording; revision retained a corrupted ending. Neither control establishes a measured false-correction rate.

## Earlier selective-vocabulary diagnostics

Both models recovered the English person-name target in both conditions. Neither recovered exact canonical spelling for the other two targets. Independent transcription from the older model rendered the Chinese names in phonetically plausible characters, while revision retained the wrong first-name form. Current-model independent transcription returned an empty person-pair response. Three acknowledgment responses requested audio despite receiving it and reporting audio input tokens. One target response inserted a glossary name near the clip end without independent evidence that it was spoken.

These results motivated the broader roster condition; they must not be merged into its accuracy result.

## Usage and latency across all rounds

| Run | HTTP 200 responses | Median latency | Range | Text input tokens | Audio input tokens | Text output tokens |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Realistic roster, `gpt-audio-1.5` | 10 | 1.95 s | 0.78–2.72 s | 4,538 | 2,042 | 524 |
| Selective vocabulary, `gpt-audio-1.5` | 10 | 1.92 s | 0.99–2.30 s | 2,288 | 2,042 | 543 |
| Selective vocabulary, older snapshot | 10 | 2.14 s | 1.05–2.67 s | 2,288 | 2,042 | 582 |
| Total | 30 | — | — | 9,114 | 6,126 | 1,649 |

There were 31 requests including the initial server error. Completed HTTP 200 requests contained 613.80 seconds of audio; the failed attempt additionally contained 24.54 seconds. Usage comes from response metadata, and the failed attempt reported none. Actual billing was unavailable; no billed cost is claimed. These are request timings, not an end-to-end live correction benchmark.

# Limitations and next steps

Locations were selected from known errors, there is no no-context ablation, and each condition was sampled once. Confidence-based detection was not tested. The user-provided targets offer limited ground truth; no complete human-verified reference or independent listening assessment was produced. Overall accuracy and false-correction rates remain unmeasured.

Before integration, compare dedicated transcription models and audio-chat models on held-out speakers and meetings, assess confidence-based detection recall, and measure vocabulary-induced insertions. Preserve original text whenever results are empty or invalid. Suggestions should remain reversible and never overwrite later user edits.

Private manifests, WAV clips, exact prompts, raw responses, and the detailed before/after report are under ignored `private/`. Tracked files contain no real meeting names, passages, people names, or library identifiers.
