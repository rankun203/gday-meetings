---
title: Real meeting transcript review
date: 2026-10-06
status: partial-listening-review
scope: audio-retrieval-experiment
---

# Problem

Synthetic speech did not represent the real recording conditions. Imported text also could not establish the behavior of Apple's live recognizer.

# Implemented solution

Added reproducible excerpt preparation, quiet-gap selection, paired room listening clips, Apple/GPT transcription, and a private discrepancy queue with text-only semantic triage under `experiments/audio-retrieval/real/`. Selected ten real five-minute excerpts: six Chinese remote project calls, three English remote project calls, and one noisy, low-voice English room recording. The nine remote samples retain microphone and system tracks separately; the room sample uses its microphone. Selection spans 01:00–06:00, fixed before comparing output. The input is 50 minutes of meeting time and 95 minutes across 19 source tracks.

The script reads the OpenAI key from the script-only environment file without displaying it. It leaves the app's Keychain and provider settings untouched. Real titles, person names, library IDs, source mappings, transcripts, audio and service receipts remain in ignored local artifacts. The main results now exclude synthetic speech from model-selection evidence.

# Reasoning

GPT is used only to draft a better evaluation reference, not as an app transcription candidate. The noisy, low-voice room excerpt is reviewed first. Both recognizers receive identical decoded samples without added noise, denoising or gain changes. Apple's finalized replay uses the app's live preset. GPT uses the requested live transcription model with high delay and explicit 20-second turns; it receives no existing transcript or name hints. The review filter requests listening only for potential GPT-only content and retains agreements without calling them ground truth.

The quiet-room follow-up uses the imported transcript as an additional baseline, because an Apple/GPT-only discrepancy queue hides speech both fresh recognizers may capture. Scanned the recording for low-level signal in sparse transcript intervals, then transcribed 12 forty-second windows and a user-selected 95-second interval. The latter overlaps one window: 575 seconds per recognizer, 535 unique seconds. All 26 receipts are complete. Original and constant-gain listening copies are available privately; recognition used unchanged gain. The selected interval contains a passage in both fresh drafts absent from the imported text, pending listening verification. No retrieval scores were changed.

# Technical debt

Quiet-gap selection uses fixed exploratory energy thresholds and approximate segment coverage; it cannot distinguish speech from noise. Retain candidates and use listening review before forming evidence labels. These targeted windows are not an accuracy sample. Fixed GPT turn boundaries provide coarse review times because the API has no word timestamps. They can split speech and affect recognition; retain them for this bounded first review, then compare silence-aware commits or a timestamp-capable reference path before deriving aligned benchmark labels. The lexical filter can miss changes using the same words. A text-only semantic pass removes apparent equivalents, but its exclusions may be wrong. Preserve all raw candidates for audit; human listening remains required, and a representative reference sample is needed before reporting ASR error rates.

# Progress and validation

Both recognizers completed all 19 source tracks. The Apple harness required access to installed speech assets; the sandbox alone returned an empty locale list. GPT produced 285 final turns; audio hashes, turn identities and interval coverage were verified. Five Apple tracks and three GPT tracks contain no text; these were retained.

The initial filter found 154 lexical candidates. GPT-5.6 Luna text-only triage classified 56 as equivalent and retained 98 meaningful or uncertain differences. One duplicate across tracks was grouped, leaving 97 listening items and a ten-item first pass. This is a review queue, not an accuracy result; ten first-pass items now have user annotations, yielding 22 explicitly reviewed spans. Another 87 items have no annotations; no complete five-minute reference is verified. The triage receives only selected paired text, uses structured output and disables response storage. Its quoted spans and IDs were validated.

Eleven synthetic text tests and Ruff checks passed. All review links resolve to private audio clips. The reports were checked for selected meeting titles, library IDs and person names. This is finalized replay, not a live-latency measurement. No app code, app provider setting, Keychain entry or meeting file was changed. The optimized Apple harness from the prior experiment was reused; no new Swift implementation was introduced.

The priority room excerpt has eight reference questions in the private review package; one is annotated and seven remain unannotated. Added hash-checked annotation import with an exact source snapshot, separate context-only evidence and partial-span exports. The renderer now refuses existing outputs to preserve user edits. Disjoint corrections retain their gaps; an inaudible identity stays outside the audio reference, and a corrected discourse boundary is retained without assigning speaker identity. The initial pass covers 01:00–06:00 only; it does not establish reference quality for the entire recording.

The supplementary semantic triage rejected one response whose highlight was not verbatim input. That response was not used to suppress review items; the room comparison retains all paired drafts. Renderer outputs refuse overwrites.
