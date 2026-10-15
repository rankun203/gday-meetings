---
title: Local diarization comparison
date: 2026-10-14
status: measured
scope: experiment
---

## Problem

Evaluate whether DiariZen Large-s80-v2 offers a useful alternative to the app's Community-1 diarization. Published benchmark results do not establish quality or resource use on this Mac and recording.

## Implemented solution

`experiments/diarizen-comparison/` contains pinned local setup, identical audio preparation, process resource measurement, normalized turn output, shared transcript projection, and an offline listening review generator. Inputs, downloaded weights, audio, and generated transcript artifacts remain in ignored local storage. `RESULTS.md` records measured aggregates and limitations.

## Reasoning

Run each engine sequentially on the same two complete source tracks. Compare acoustic behavior separately from projection coverage. Preserve model thresholds and avoid accuracy claims without reference labels. The measured runtime excludes transcription and People Library association; Community still computes embeddings required for speaker clustering.

## Technical debt

The upstream Python inference environment requires a recorded one-line migration from the deprecated SpeechBrain import. This compatibility patch preserves the selected embedding implementation; remove it when upstream adopts the supported namespace. The CPU Python candidate and Core ML baseline use different compute configurations, so resource results describe these implementations rather than model architecture alone. An accelerator comparison and labeled reference sample are required before making broader speed or accuracy claims.

## Validation

Pinned imports and two 30-second compatibility runs passed. Synthetic resource-wrapper, acoustic-metric, and review-generation checks passed. Both complete engine runs finished. Community inference took 14.12 seconds and DiariZen 1,665.63 seconds; peak process RSS was 0.584 GB and 5.001 GB respectively. The same frozen projector assigned 4,408 and 4,435 of 5,031 timed spans. These are resource and coverage measurements, not accuracy scores. The generated private listening review includes 12 windows and both projected transcripts; JavaScript syntax and local-only structure checks passed. Browser interaction was unavailable because the browser tool rejected local file access, so playback and visual validation remain for user review. App foundation release validation is recorded separately in the diarization projection worklog.
