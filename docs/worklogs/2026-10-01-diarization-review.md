---
title: Local diarization listening review
date: 2026-10-01
status: completed
scope: experimental-review-app-and-comparison
---

# Problem

Saved transcript speaker labels are not independent audio annotations. Reviewers need a local interface to mark speech ranges, overlap, and uncertain audio before comparing systems. Earlier comparison reports also excluded two recordings because they interpreted trimmed worker durations as full input durations.

# Implemented solution

The app under `apps/experiments/diarization-review` uses a localhost Python server and browser controls, with private audio, annotations, backups, exports, and generated validation artifacts under root `tmp/`.

Three sub-agents implemented the backend, interface, and comparison report. The reference audit establishes eligibility for all four selected recordings without shifting or stretching timelines. Fresh-process startup and five-minute paced measurements resumed after the approval service recovered: 14 successful receipts passed hash and paired-input checks, with the earlier failed receipt preserved and excluded. Reports distinguish cached loading, speech processing, observed process resources, and unknown accelerator allocation.

# Reasoning

Independent annotation hides system predictions and uses anonymous speaker IDs within each recording. Explicit completion defines reviewed coverage; uncertain audio remains excluded. Optimistic revisions and atomic saves protect annotations when multiple tabs are open.

The interface design uses clip navigation, a waveform with draggable ranges, speaker lanes, playback and selection controls, and an exact-time inspector. No existing review screen was present. The previous handover authorized implementation without screenshots while browser access was blocked. After access recovered, the initial static layout was captured and inspected before interaction code was implemented. The three columns and controls fit the inspected 1434 × 862 viewport.

# Technical debt

The app reuses the existing experiment's exporter and scorer through a sibling source import. This avoids duplicating evaluation rules but couples the app to that directory layout; extract a shared package if another consumer is added. Conflict drafts are preserved for manual reconciliation rather than merged automatically; add a comparison/import flow if concurrent review becomes routine. Local model labels follow preparation order; the private key retains the source mapping.

The existing Community-1 replay adapter retains window-local identities, so these experiments cannot establish stable live speaker identity quality. A future live evaluation needs an explicit identity and output-availability policy. Cached startup and process memory do not establish first-install latency, energy use, or total accelerator memory.

# Validation

The existing review, gold-scoring, and reference regression suites passed (34 tests). Seven backend synthetic tests passed for persistence, conflict detection, drafts, nested metadata isolation, HTTP origin checks, audio bounds, and export. JavaScript syntax and uncertainty/coverage helper checks passed. No Swift code changed, so macOS release validation was not applicable.

Chrome checks with synthetic pulsed tones verified waveform rendering and selection, keyboard labeling after playback, overlapping speakers, dragged range edges, selection replay, undo, saved speaker references, save/reload, uncertainty coverage subtraction, explicit Finish/Next, conflict detection, draft preservation, recovery, and export/scoring display. The final synthetic screenshot is under ignored `tmp/diarization-review-preview-tones/review-validated.png`. Main audio playback state was observed; no human or automated listening judgment was made. Browser coverage does not establish assistive-technology, mobile, or other-browser behavior.

At this stage, the prepared review server ran at `http://127.0.0.1:8766`, and all 52 prepared clips were unreviewed. Opening the local meeting samples verified anonymous clip navigation and audio decoding without changing labels. The [later review expansion](2026-10-01-local-meeting-review-expansion.md) records the completed annotations and comparison. All generated artifacts remain under root `tmp/`.

The first browser navigation to the protected server failed because the request arrived as a cross-site document navigation. The server now allows navigation to its public static shell while retaining origin checks for private data and mutations; HTTP tests and browser request metadata verified the fix. UI review also found that waveform dragging needed explicit keyboard focus after audio playback; the correction passed browser validation. The full prepared set exposed a long sidebar, so navigation now scrolls independently within the viewport.
