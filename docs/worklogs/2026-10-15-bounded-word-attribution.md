---
title: Infer word attribution from bounded edge overlap
date: 2026-10-15
status: validated
scope: macos-diarization-projection
---

## Problem

Native word timestamps can include substantial leading or trailing time outside an acoustic turn. The existing midpoint rule leaves those words unresolved even when one speaker has positive support. Newly saved native timing makes this distinction observable; it does not establish whether unsupported time is silence or speech missed by the model.

## Implemented solution

The projector retains its direct midpoint rule. For a precise word lasting at most 1.5 seconds with exactly one overlapping speaker identity, an additional inferred assignment requires all of:

- At least 100 milliseconds of overlap with one acoustic turn.
- At least 25% coverage of the word interval by that turn.
- No unsupported leading or trailing edge longer than 750 milliseconds.

The inferred result remains uncertain and stays separate from certain attribution during canonical grouping. Text, original timing, and source anchors remain unchanged. Manual assignments remain protected. Existing competing-speaker and coarse-run rules remain unchanged, including rejection of simultaneous voices. There is no new nearest-speaker assignment for zero-overlap words; the existing short gap bracketed by the same voice is the only zero-overlap fallback.

## Reasoning

Absolute support rejects incidental interval intersections; relative support rejects words dominated by unsupported time; the explicit edge bound prevents a long unsupported boundary even when the coverage fraction passes. These are conservative engineering guardrails, not thresholds calibrated against ground-truth speaker annotations. A proposed weaker 80-millisecond/15% candidate was rejected for implementation because it admitted much more weak evidence and risked fitting the reported examples.

A read-only sensitivity calculation used all eligible spans in copied meeting artifacts with the same acoustic result, not only selected screenshot windows:

| Transcript | Eligible single-speaker words with midpoint outside speech | 80 ms / 15% candidate | 100 ms / 25% / 750 ms edge candidate |
| --- | ---: | ---: | ---: |
| Native | 474 | 328 | 145 |
| Remote worker | 234 | 151 | 91 |

Counts are additional words eligible under each rule, not accuracy scores. Calculations use the strongest individual overlapping turn, matching the implementation, rather than summing duplicate or disjoint support. Listening review and independent annotations are required before interpreting the extra assignments as improvements.

## Technical debt

The guardrail constants remain uncalibrated. The conservative values bound the risk while retaining uncertainty; the consequence is that some audible words remain unresolved. Future remediation is to evaluate these rules against independently annotated held-out recordings before changing the defaults. No schema changes or stored-transcript migrations were added.

## Validation

Root review and 22 release tests across projection, copied-artifact preservation, and passage presentation passed. Synthetic cases cover leading and trailing overlap, tiny intersections, insufficient relative support, excessive unsupported edges, long words, coarse runs, competing adjacent speakers, simultaneous voices, zero-overlap boundaries, manual assignments, separate uncertainty, and repeat application. Swift formatting and whitespace checks passed.

The copied native transcript retained all 14,820 spans and every source character and anchor. Attributed spans increased from 13,144 to 13,289; the additional 145 assignments remain uncertain. Projection took 0.166 seconds. This is a coverage measurement, not a speaker-accuracy result. Isolated `make build-macos` passed in 210.88 seconds. Existing Command Line Tools linker search-path warnings remain for absent `Developer/usr/lib` and `Developer/Library/Frameworks` directories; this change adds no deprecated API use. Repairing the installed toolchain paths remains a separate environment follow-up.

No inference, retranscription, model-parameter changes, or library writes were performed for this projection change. The user declined worker changes requiring deployment; those investigation edits were removed. Automatic review initially rejected the separate comparison's private-audio transfer. After the user explicitly authorized the destinations and paid job, the isolated runner uploaded copied tracks and submitted one job to the existing worker. Its output remains separate from the library.
