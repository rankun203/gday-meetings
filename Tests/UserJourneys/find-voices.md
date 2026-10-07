---
title: Find Voices while using the library
date: 2026-10-07
status: draft
scope: macos-user-journey-performance
journey_id: find-voices
---

# Find Voices while using the library

## Intent and questions

I want to discover voices across recordings while continuing to use the app. Is elapsed time explained by useful inference, audio preparation, model startup, storage, or redundant work? Does saving progress block navigation? Does resume reuse completed analysis?

The reported low completion count after a long wait is a symptom, not normalized throughput or a confirmed diagnosis.

## Setup and variants

Follow the [shared procedure](README.md#shared-run-procedure). Propose ten synthetic 5-minute recordings initially, then longer recordings after agreement. Record total audio duration, track count, formats/sample rates, speakers, existing labels/examples, and prior analysis receipts. Record both selected provider and actual discovery model; a display name alone does not establish which model runs.

| Variant | State | Question |
| --- | --- | --- |
| A | Unlabeled cohort, first run | Startup and first-result cost |
| B | Fresh matched cohort, models warm | Steady throughput |
| C | Paused or already analyzed work | Checkpoint and reuse behavior |
| D | Matched compressed/PCM speech | Audio preparation cost |

A warm throughput test still needs unprocessed recordings. Repeating completed work measures reuse. Keep content/duration matched for format comparisons. An invalid synthetic file can be added later; never damage user recordings.

## Natural language actions

1. Record initial progress/examples and start Find Voices in Recordings for the disposable cohort. If the app cannot restrict it to that cohort, resolve setup before starting whole-library analysis. Measure running state, first analyzed recording, and first usable result. Initially observe without interaction.
2. While analysis continues, switch among Meetings, People, and Tasks. Open a saved synthetic meeting, scroll its transcript, and add a generic note. Observe clicks and typing around progress/result updates.
3. Open Voice Review when available, browse existing examples, and return to Tasks. Watch selection and repeated refreshes. Avoid changing review decisions in the first matched throughput comparison.
4. After two recordings finish, request Pause. Time actual work stopping separately from visible state change. Confirm completed progress remains; navigate while in-flight work settles.
5. Resume and check progress advances from the checkpoint. Capture the next transition and look for repeated completed analysis using available events, not progress text alone.
6. Finish the small cohort and inspect warnings, saved examples, and availability. For larger runs, agree on a time budget and take short captures at startup, steady work, and transitions. Pause the test job at the agreed end and report partial completion honestly.

## Measurements and profiling

Use Time Profiler/Hangs for interaction and transitions, Thread State Trace for waits, and File Activity for checkpoint writes. Add Core ML/GPU/ANE where supported in a matched pass. Observe model loading/compilation and prediction, memory pressure, and thermal state. Report unavailable instruments explicitly.

Separate inventory/read, decode/resample, model acquisition/load, inference, extraction, result save, and publication times where instrumentation allows. Missing stage timing is a gap, not a guessed breakdown. Record audio seconds analyzed per elapsed second and real-time factor: elapsed analysis seconds divided by analyzed audio seconds. State whether multitrack audio duration sums tracks or uses meeting duration, and keep the definition consistent. Report failed/skipped inputs separately from successful throughput, alongside examples, retries, reused work, CPU time, stalls, memory, hardware activity, and pause latency.

Compare analysis alone with analysis during matched interaction. Inspect repeated model loads, idle gaps, decode cost, synchronous writes, and redundant work as candidates. High accelerator utilization alone does not establish efficiency, and meeting count alone ignores recording duration.

## Expected experience

Navigation and typing remain responsive while analysis progresses. Pause stops new work and settles in-flight work within an explainable measured interval. Resume retains completed analysis and saved examples remain available. Throughput targets depend on hardware, model, duration/format, and valid output; establish a baseline before setting them.

## Open decisions

Choose representative formats/durations, time budget, pause target, and whether concurrent recording belongs in a later stress case. Check discovery coverage and valid output so faster processing is not achieved by silently skipping useful work.
