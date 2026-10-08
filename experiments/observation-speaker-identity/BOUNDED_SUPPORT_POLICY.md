---
title: Bounded exclusive activity support, revision two
status: development candidate before new confirmation
---

This revises the earlier continuous-run experiment before any inference on the new confirmation cohort. A known local activity run is not unlimited evidence for the same voice: the shared live/post-meeting helper therefore limits inferred support to 30 acoustic seconds before or after physical sample support, as well as the connected exclusive run and window bounds. Live publication still has its independent 30-second correction horizon.

Keep all acoustic thresholds, the frontend, and physical sample eligibility unchanged. Stop inferred support at any silence gap, overlapping local track, contradictory/provisional observation, or persisted missing-audio interval. Missing-audio intervals also exclude direct publication within the omitted interval. The same indexed source sweep is used by live projection and saved consolidation. Bootstrap query is excluded because its development cells showed no timeline benefit.

The actual adapter emits `bounded-exclusive-contiguous-run-support-v2-experiment`. Preserve the previous unbounded diagnostic and frozen v10 validation failure as distinct results. Evaluate all four original development schedules and five human-reviewed regression recordings on a passing immutable snapshot before opening the new disjoint confirmation cohort. The additional four user-selected recordings have no human truth; report coverage and decision diagnostics, listenable examples, and saved-provider disagreement separately.
