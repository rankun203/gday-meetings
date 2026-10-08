---
title: Development experiment for bounded continuous speech support
status: preregistered diagnostic
---

Keep the frozen v10 frontend, voice thresholds, and identity decisions. Change only the support of an already accepted clean embedding after its window reaches capacity. A local label is evidence for one uninterrupted exclusive activity run; it cannot carry a person's identity across a gap, an overlapping local label, or the next window.

Construct connected components of activity with exactly one local label active on the source, using exact adjacency with a numerical 1e-6 tolerance. An accepted nonprovisional observation may support its own component beyond its physical PCM spans. Any incompatible, unresolved, or provisional observation intersecting that component prevents extension. Retain all unresolved time and existing authoritative assignments. Extend only unresolved post-capacity activity, within the original window, with the same 30-second revision horizon from recorded embedding availability. Do not bridge disjoint fragment support through silence or overlap.

First run a post-meeting diagnostic on the four **development** recordings. Final assignment and alias metadata make this diagnostic an upper-bound hypothesis, not an actual causal implementation or acceptance result. Report additional assigned seconds, all unchanged timeline duration, confusion, coverage, merge precision, and split recall. If useful, implement the same contract in the actual adapter and repeat its recorded callback replay. The spent validation result remains reported; the newly prepared disjoint cohort is unopened until a new policy passes development gates.
