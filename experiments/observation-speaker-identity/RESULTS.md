---
title: Observation-based speaker identity evaluation
status: archived; experimental live pipeline removed
scope: acoustic identity, timeline publication, full-recording diagnostics, and resources
---

# Findings

**Historical report:** the user subsequently removed live diarization and the observation/consolidation pipeline in favor of post-recording Speaker Diarization. The figures below describe frozen former implementations. Their dependent runners were removed; they do not validate the replacement architecture.

The current production release keeps the legacy identity policy. Bounded v12 remains an evaluated candidate because the known fragmentation regression below is unresolved; its source-frozen metrics do not imply activation.

The final bounded v12 pipeline passes all nine primary development comparisons and the newly frozen twelve-voice confirmatory cohort. It does **not** satisfy an unqualified no-regression claim: when rerun on the previously spent validation cohort, saturated ownership confusion remains 9.496% versus the original 7.984%. This is improved from v10's 13.245%, with more correctly attributed speech and fewer false merges, but also more fragmentation. That known limitation is not erased by success on the new cohort.

All eight full source recordings from four additional real meetings completed model and actual-adapter replay, followed by four derived combined-source replays. These have no reviewed human truth. The capacity resource probe confirms reuse of the loaded models: a host-state reset took .351 ms and twelve seconds of bootstrap processing took 1.138 seconds. The observed original microphone reset storm was separately traced to capture resampling continuity and repaired without changing AGC. Final integrated activation/release decisions remain with the parent task; these results do not authorize an unqualified accuracy or responsiveness claim.

# Setup

All processing uses local models and saved audio. Frontend inference, the actual live adapter, and post-meeting consolidation have separate immutable source/binary/input receipts. Recorded embedding availability uses the submitted-audio upper-bound clock; it preserves callback order but is not a concurrent recording-latency measurement. The live adapter preserves a 30-second mutable tail and persists subsequent identity aliases without dropping unresolved speech.

The public development set contains four source-owned schedules: arrivals/returns, short turns, saturated rearm, and a six-speaker overlap control. Ownership includes internal pauses and is not human speech activity truth. Its metrics therefore are **source-ownership conditional confusion**, coverage, merge precision, and split recall, not DER. The original frontend remains the comparator even when a new frontend changes its own local-label baseline. All mappings are fitted once per full recording, never separately per owner or stratum.

Five previously examined private recordings (J, B, G, D, C) contain saved human-reviewed random and targeted excerpts plus worker references. These are development/regression controls, not new holdouts. Human DER uses the unchanged reviewed boundaries; targeted excerpts are reported separately from random excerpts. Saved RunPod output is a silver reference, not human truth; comparisons that use it as the reference are disagreement measurements. Where reviewed human intervals exist, the worker can also be scored as a competing hypothesis against those same intervals. The historical worker deployment lacks a reproducible revision receipt. DER can exceed 100% when extra predicted speaker-time is substantial.

The sampler policy is preregistered in [MULTISPAN_POLICY.md](MULTISPAN_POLICY.md). It retains clean completed 300 ms–3 s fragments within one trusted source/local label/generation, requires at least two seconds of actual PCM, and bounds support to 30 seconds, eight spans, and six seconds of PCM. Ordinary three-second sampling, five-second spacing, and .7/<.2 posterior purity gates remain. Actual support spans govern overlap, physical sample independence, representative playback, and direct timeline evidence; the enclosing gap never becomes sampled speech.

# Final bounded v12: new frozen confirmation

The final bounded candidate shares one live/saved support sweep, limits extension to 30 acoustic seconds around physical evidence, and preserves explicit gaps as barriers. Its immutable snapshot passed 80 tests in 14 suites. All nine existing development primary comparisons passed; the five historical saved-audio comparisons remained unchanged. Bootstrap identity queries were excluded because they added no measured development benefit.

After these gates, a new twelve-voice disjoint cohort was opened under frozen policy `b7249d1fbc801758690e3dbfc47c9e224ea04e5793f7ddefe3b58b1cc0aa31bb`. No parameters changed after its results. Conditional source-ownership confusion against the receipt-verified original frontend was:

| New confirmatory scenario | Original | Bounded v12 |
|---|---:|---:|
| Arrivals and returns | 35.834% | 2.250% |
| Short turns | 23.697% | 23.697% |
| Saturated rearming | 48.568% | 16.926% |
| Six speakers with overlap | 0.000% | 0.000% |

These are synthetic source-ownership comparisons, not human meeting DER. The earlier disjoint v10 saturation failure remains a failed validation result above; it has not been relabeled as development success. The first confirmatory driver used one shared output path and stopped after its first successful input; that result is preserved, and the complete rerun uses separate output paths with the same frozen policy.

The confirmatory guardrails also remain visible: arrivals ownership coverage changes 87.050%→86.975% (0.12 s less), merge precision .8862→.9588 and split recall .6269→.9594. Saturation coverage changes 91.804%→93.493%, precision .9149→.9966 and recall .4581→.7649. Short-turn and six-speaker values are unchanged; six-speaker overlap set precision remains 1.0 and recall .9424.

# Final-policy check on the spent cohort

This is a known regression check, not another holdout. The same source-hashed historical frontend evidence is reused only after verifying that model inputs, sampling, bootstrap settings and frontend build receipt match the final frozen policy. A new actual-adapter receipt binds bounded v12. No tuning followed these results.

| Source-ownership confusion | Original | Historical v10 | Final v12 |
|---|---:|---:|---:|
| Arrivals and returns |27.242%|11.810%|10.317%|
| Short turns |16.971%|16.971%|16.971%|
| Saturated rearming |7.984%|13.245%|**9.496%**|
| Six-speaker overlap |0.675%|0.675%|0.675%|

Saturation coverage rises 81.750%→90.649%, correctly paired time 111.33→121.42 seconds, merge precision .8675→1.0; confused time also rises 9.66→12.74 seconds and split recall falls .9821→.8714. Thus there are 10.09 additional correct seconds and 3.08 additional confused seconds. The strict conditional-confusion no-regression gate remains failed. Artifact: `tmp/observation-bounded-v12-20261008/spent-regression-final.json`; `score_known_regression.py` preserves both historical and candidate policy bindings.


# Development and reviewed private controls

All percentages in this table are ownership confusion, not DER. The four schedules are the same development inputs throughout.

| Complete timeline | Arrivals | Short turns | Saturated rearm | Six-speaker control |
| --- | ---: | ---: | ---: | ---: |
| Original local-label comparator | 15.355% | 17.000% | 40.368% | 0.200% |
| Pending identity, original frontend | 17.454% | 17.000% | 26.584% | 0.200% |
| Credible resets, 45-second suffix | 26.508% | 39.756% | 27.375% | 0.200% |
| Credible resets, 12-second suffix | 13.137% | 33.012% | 21.834% | 0.200% |
| 12-second suffix + explicit short-turn support, v8 | 13.137% | 21.642% | 8.156% | 0.200% |
| v9/v10 recognized global return + deterministic initial aliases | 11.114% | 16.119% | 8.156% | 0.200% |
| Final bounded v12 | **11.114%** | **16.119%** | **5.862%** | **0.200%** |

The shorter suffix improves coverage as well as confusion: arrivals ownership coverage rises from the original 83.49% to 92.46%, and saturated rearm from 83.72% to 91.29%. The short-turn gap is fragmentation, not discarded audio. Short-turn accumulation raises owners with sampled single-owner support from 5/12 to 11/12. Observation counts become 20/14/28/13; single-owner support covers 12/12, 11/12, 11/12, and 6/6 owners.

One arrivals observation concatenates fragments from two actual owners sharing a predicted local label. It remains included. This is an observed limitation of local-label-based accumulation despite confident individual frames; explicit support makes it inspectable but does not guarantee purity. No reference labels filter candidate evidence.

The v9 short-turn tradeoff is explicit: coverage rises 76.13%→82.06%, correctly paired time rises 56.83→61.82 seconds, merge precision rises .7783→.9242, and split recall falls .9507→.8047. Absolute confused time rises slightly, 11.64→11.88 seconds, while the conditional fraction falls because more speech is represented. Saturated rearm adds .38 seconds of activity in injected silence (1.26→1.64 seconds). The complete overlap-control metrics are unchanged.

All five historical private batch controls preserve prior random-review results under v9: J 25.780%, B 15.965%, G 19.887%, D 114.246%, C 19.406%. Those establish compatibility only. Fresh full audio controls through v9 follow; the worker column is scored against the same reviewed human intervals, not treated as ground truth.

| Private random-review control | Original raw client DER | Fresh v10 client DER | Saved worker DER |
| --- | ---: | ---: | ---: |
| J | 25.780% | 25.593% | 18.207% |
| B | 15.965% | 15.965% | 27.472% |
| D | 117.640% | 97.759% | 74.999% |
| G | 19.887% | 19.887% | 21.011% |
| C | 19.406% | 19.406% | 18.051% |


The C regression is an evidence-retention bug, not a known-return threshold failure: v8 and v9 outputs are identical. Three fragment observations satisfy the sampler's 30-second acoustic envelope but arrive 30.60–31.22 seconds after their oldest support. The core rejects them as older than its retained constraint history, then treats that omission as an ambiguous identity boundary. One such boundary adds 5.534 confused seconds in reviewed excerpts. All other fresh private controls have zero unassigned sample events. V10 retains 60 seconds of physical constraints (30-second sample envelope plus up to 30 seconds accepted arrival lag), while publication corrections remain bounded to 30 seconds. Evidence older than retained support is explicitly ignored rather than turned into contradictory identity evidence. C now has no expired or unassigned samples.

J's targeted reviewed excerpts improve from original raw 47.153% to fresh v9 32.371%; this value was preserved through the final bounded adapter. The worker remains stronger on some random controls, while the local pipeline is stronger on others. No universal superiority claim follows from this small reviewed set.

# Four additional full real meetings

Eight complete microphone/system sources, approximately 3 h 26 m of meeting time, were decoded with original/PCM hashes and replayed serially. No originals were edited or uploaded. All eight actual-adapter publications preserve the eligible model-observed activity union. Four additional combined-source adapter runs preserve lineage while interleaving submitted-audio availability; this is not original concurrent capture scheduling or latency. A premature combined-source attempt correctly refused a missing second-source receipt and was retried after both sources completed.

| Private source alias | Embeddings | State transitions | Unresolved activity | Provisional activity |
|---|---:|---:|---:|---:|
| recent-01 microphone |9|0|0.00 s|46.52 s|
| recent-01 system |812|2|7.43 s|0.00 s|
| recent-02 microphone |456|1|2.99 s|80.14 s|
| recent-02 system |0|0|0.00 s|0.00 s|
| recent-03 microphone |5|0|0.00 s|12.44 s|
| recent-03 system |91|1|1.55 s|1.71 s|
| recent-04 microphone |178|0|0.00 s|5.53 s|
| recent-04 system |310|1|5.14 s|7.26 s|

These are diagnostic counts, not participant counts, split/merge accuracy, or speech recall. Recent-02 system has no predicted activity and low recorded RMS (~−65.5 dBFS); this is not proof that every sound was correctly rejected. The legacy saved-provider comparison is bound to original audio but has no verified deployment/diarization revision: microphone disagreement changes34.254%→34.377%, system37.075%→26.343%. These are silver disagreements, not human DER or verified RunPod accuracy. Native People assignments may contain the user's reported errors and are not gold labels.

Five capacity transitions across the eight sources replay sixty seconds of buffered audio. On active tracks the measured rates are1.37,1.15,5.36 and1.09 transitions per audio-hour; the short11-minute source makes the per-hour rate larger without implying a storm. Bootstrap replay is respectively .456%, .384%,1.786% and .365% of source audio. No fresh processing gaps occurred. There is no unresolved activity in the first twelve seconds after the observed handoffs, but this descriptive measure is not a causal bootstrap-cost estimate.

The original recent-01 microphone journal instead has16,449 generations with **zero** capacity-reached windows. Repeated100 ms generations begin11.8 ms after a route change to48 kHz; windows carry~84.3 ms before artificial gaps. Quiet recorded periods also exhibit the resets. This supports the reproduced resampler-timing cause, not an inference that gain control or eight distinct voices triggered resets. Label-processing gap union3,565 s is not recorded-audio loss. See the separate capture worklog.

Private aggregate: `tmp/user-meeting-final-summary-v12-20261008.json`. Listen at `tmp/user-meeting-review-v12-20261008/index.html`: targeted capacity/handoff/uncertainty/overlap/provider-disagreement samples, deterministic random controls and microphone-route diagnostics. These clips are review material, not annotated truth or full-meeting DER.


# Compute and correctness evidence

The multi-span frontend and legacy-compatible adapter snapshots pass 40 focused tests in 14 suites, including physical-support playback, omission journals, backward serialization, uncertainty, manual review, and undo. Forty Python harness tests pass without skips. Failed safety builds were retained and corrected before inference; they did not produce accepted metrics.

The frozen v9 post-meeting core scaling experiment repeats real evidence with distinct local/window IDs. Three alternating runs per size produce byte-identical outputs. A 60-minute input (298 embeddings, 5,667 activity intervals) takes a median .187 seconds and 22.14 MiB peak RSS; a 120-minute input (590 embeddings, 11,370 intervals) takes .460 seconds and 35.27 MiB. The 120-minute range is .430–1.179 seconds. Concurrent CoreML work was active, so these are loaded-machine observations. The fixture repeats nine voices; it does not establish scaling to hundreds of distinct people. Audio inference, persistence, UI, and People matching are excluded.

The actual-stream reset benchmark compares the committed baseline with the candidate using 150 synthetic resets, 1,200 allocated speakers, and 450 callbacks. Final phrase snapshots match exactly. Main-thread CPU falls from 17.996 to .881 seconds; last-quarter callback p95 falls from 82.422 to 2.418 ms, and maximum callback time from 121.530 to 2.622 ms. This is one source/binary-bound debug run; it excludes capture, model inference, and UI rendering and therefore does not prove whole-app responsiveness. The earlier 1,200-reset attempt exceeded its 300-second timeout before a phase receipt and remains preserved separately. Evidence: `tmp/live-stream-reset-regression-20261008/bounded/receipt.json` and `metrics.json`.

## Quiet actual rollover resource probe

A source-hashed0–1820 s busy real-audio prefix preserves causal lead-in to one capacity event. Host reset .351 ms; old-state flush58.745 ms; twelve-second bootstrap1.137718 s; complete rollover1.197190 s. Model objects loaded remain3→3 and preparations2→2 from startup to finish: rollover does not reload the model. Extra processed audio is12/1820 s (.659%). Full-process wall210.32 s, CPU75.05 s user+3.70 s system, maximum RSS168.48 MiB; these include the test harness, embeddings and trace. Only wall stages are isolated, not stage CPU.

The coordinated run excluded other agent builds/model inference, but foreground user load was uncontrolled. It is accelerated serial replay, not simultaneous live capture/transcription or an energy measurement, and measures one rollover rather than a universal bound.600 bootstrap processing calls are20 ms audio blocks, not600 neural predictions. The initial launcher failed before inference because of stripped runtime paths; its failed receipt is retained. No policy tuning followed the successful measurement. Source/binary/input receipts are under `tmp/observation-rollover-cost-20261008/`.


## Native transcript stress probe

The actual AppKit transcript table passed two 30-second runs under concurrent CoreML replay load, with 1,000 and 10,000 rows, 1,800 scroll operations and 60 reset/gap attribution updates each. Layout p95 was 4.56/7.81 ms; callback p95 was 19.31/18.48 ms. Maximum layout was 125.78/90.56 ms: one operation exceeded 100 ms in the 1,000-row run. Main-thread CPU was 7.43/14.27 seconds over each 30-second run. These are native layout/callback measurements, not presented-frame rates (`screenRefreshCount=0`), and inference ran in another process. The single observed hitch remains a limitation rather than being omitted.

# Remaining release decision and limits

The acoustic result has a known fragmentation tradeoff on one spent cohort. Any default activation must acknowledge that result; do not state that all accuracy metrics or all no-regression gates pass. Final integrated capture, People review/undo, UI and release checks remain separate from the frozen acoustic experiment. No further threshold tuning or new experiment is part of closing this task.

The projector is not an identity metric; comparisons use compatible original-space embeddings. Human-reviewed coverage is limited, source-owned fixtures are synthetic, and the four full meetings lack human truth. Preserve provisional/unresolved time and report raw versus settled aliases and coverage beside confusion. The queued Community short-window segmentation comparison will hold embeddings/global clustering and AGC fixed; it has not run and is not a required pivot.


# Historical frozen v10 validation failure

The policy was frozen before inference with SHA256 `2d28a9b72c280a217a7dbe24650d84f0c36066540bcc7dc89356c4fad718dc9e`. Twelve different source speakers were reserved for this cohort. The final v10 actual adapter and unchanged frontend were evaluated without retuning. Original baseline sources, fixture, and binary match the original development comparator; both new runs use the same receipt-bound model assets. The first candidate attempt failed because CoreML could not write its normal cache; its failed receipt is preserved, followed by the same-policy successful retry with cache access.

| Conditional ownership confusion | Original frontend | Frozen v10 |
| --- | ---: | ---: |
| Arrivals and returns | 27.242% | 11.810% |
| Short turns | 16.971% | 16.971% |
| Saturation and rearming | 7.984% | **13.245%** |
| Six-speaker overlap control | 0.675% | 0.675% |

The saturation case does **not** pass a no-regression gate for conditional confusion. Ownership coverage rises 81.75%→90.65%, merge precision rises .8675→1.0000, but split recall falls .9821→.8237. Correctly paired speaker time rises 111.33→116.39 seconds, while confused time rises 9.66→17.77 seconds. This is increased coverage and fewer false merges accompanied by more fragmentation; it must not be presented as an unqualified accuracy win. The overlap control's owner-set precision (1.000) and recall (.8735) are unchanged. That v10 candidate was not accepted; its frozen parameters were not retuned. Later architecture changes were developed on the existing development recordings and assessed on a new cohort. Artifacts are `tmp/observation-multispan-20261008/validation-final-comparison.json` and the adjacent frozen policy and immutable receipts.

## Development of bounded support after that failure

After the frozen saturation result, a new independent confirmation cohort was prepared using positions 24:36 of the original hash-ordered source speakers, retaining the same seed, archive, and schedules. Its twelve speakers are disjoint from both prior cohorts; four recordings total 568.8 seconds. Selection SHA256 is `3e501fda867bf8ef5e284603defbddab1b59e66ed5324cb286f6be245d80d461`. It was not used for inference or manually inspected during design; the final bounded v12 confirmation below opened it only after development gates and policy freezing.

A preregistered [continuous support diagnostic](CONTIGUOUS_SUPPORT_POLICY.md) uses only development data. It extends an accepted embedding through the same uninterrupted exclusive local activity run after capacity, while stopping at gaps, overlaps, contradictory evidence, window boundaries, or the 30-second revision limit. All timeline time remains present. It adds 4.68 assigned seconds on arrivals without changing confusion, and 3.17 seconds on development saturation, reducing confusion 8.156%→5.862%. Short turns and the six-speaker control are unchanged. These final-assignment projections are post-meeting diagnostic hypotheses, not an actual causal adapter result or acceptance evidence. The actual adapter subsequently reproduced the development diagnostic: arrivals11.114%, short16.119%, saturation5.862%, six0.200%, with all timeline time retained. A 16-test/five-suite immutable checkpoint includes a single activity sweep to avoid repeated run construction on the main thread. A separate bootstrap-on cell uses independent timed acoustic prototypes and uncertain local anchors. It accepts one of two arrivals queries and two of four saturation queries, but produces identical scored timelines, ordinary observation counts (20/14/28/13), and provisional speaker-time. Thus continuous run support has measured causal benefit; bootstrap context has valid independent matches but no demonstrated development timeline benefit. All five fresh private regressions subsequently preserve both available random and targeted human scores with query extraction off. Bootstrap query is excluded from the production candidate because no development timeline benefit was measured. The subsequent bounded extension-only snapshot and independently frozen confirmation are reported below; the spent validation failure remains reported above.

## Earlier rejected observation reducers

The first frozen reducer used .72 admission, .08 margin, twelve representatives and fifteen-second continuity. Requiring full published-activity coverage incorrectly rejected many valid extraction spans. Correcting that gate admitted all 763 observations but did not solve the one-observation clustering/fragmentation problem. These failed human random-review results motivated temporal denoising and pending evidence, rather than an owner-specific threshold exception:

| Recording | Baseline DER | Strict-support candidate | Positive-support candidate |
|---|---:|---:|---:|
| J |25.780%|51.764%|67.194%|
| B |15.965%|23.335%|31.656%|
| G |19.887%|28.519%|36.594%|
| D |114.246%|120.781%|120.730%|
| C |19.406%|23.833%|38.568%|

Positive-support assignable speaker-time was only 38.87/20.75/24.43/13.91/18.21% respectively; provisional/unresolved time was retained in scoring. A later naive contiguous-run-only diagnostic also failed by fragmenting unsampled pauses: two-second evidence yielded arrivals16.494%, short37.140%, saturated33.185%, six10.634% ownership confusion. This was not promoted. The final approach preserves trusted pre-capacity continuity and bounds post-capacity evidence extension, with shared live/saved gap barriers. Early failed receipts remain under `tmp/observation-identity-evaluation-20261008`; the complete pre-rewrite chronology is retained privately as `tmp/observation-worklog-before-rewrite-20261008.md`.

# References and reproduction

- [Experiment README](README.md): build/replay/scoring contracts.
- [Detailed design and worklog](../../docs/worklogs/2026-10-08-observation-speaker-identity.md): current architecture and remaining release work.
- [Bootstrap experiment policy](../live-speaker-capacity/BOOTSTRAP_EMBEDDING.md): fixed suffix/extraction comparison.
- [Short-turn support policy](MULTISPAN_POLICY.md): fixed sampler bounds before inference.
- `run_frontend.py`, `run_adapter.py`, `score_public.py`, `score_live.py`, and `audit_support.py`: source-bound execution and full-timeline metrics.
- Private receipts and detailed outputs: `tmp/observation-bootstrap-20261008`, `tmp/observation-multispan-20261008`, and `tmp/observation-postmeeting-scale-v9-20261008`. These ignored directories contain private evidence and are not committed.
