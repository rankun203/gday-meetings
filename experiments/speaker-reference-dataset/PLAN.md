---
title: Speaker reference dataset construction plan
date: 2026-10-26
status: ready-for-implementation
scope: private-meeting-reference-and-benchmark-protocol
---

# Speaker reference dataset construction plan

## Purpose and accepted scope

The user found configuration-by-configuration listening too demanding and observed that settings rank differently across meetings. Build one reusable, auditable reference dataset so all candidate systems can be scored on the same evidence. It must support future encoder selection, clustering, People Library association, and correction-replay learning experiments.

The user authorizes VibeVoice-ASR processing on their Runpod account using the Swift app's environment credentials, and pyannote commercial processing when they supply access. They have Runpod credits. Begin with two or three short meetings around ten minutes each, measure resource use and cost, optimize while preserving results, then expand to full meetings from the main library. This planning task provisions no resources and uploads no audio. Another agent will implement and run it.

Authorization covers the selected meeting audio sent to these two services. Transfer only required audio and opaque identifiers, without library databases, unrelated recordings, attendee lists, app credentials, or meeting titles. Do not publish the dataset. Review provider retention controls and record the actual processing destinations and cleanup behavior before transfer.

## Non-negotiable reference rules

1. Machine output is a proposal, even when both teachers agree. Preserve raw outputs and provenance. Never promote consensus automatically to human-verified truth.
2. Reference construction must not inherit current app speaker labels, candidate clusters, embeddings, or predicted speaker counts. Existing explicit user judgments can be imported only with their exact source interval and provenance, after validating their scope.
3. Annotate on the source audio timeline independently of existing transcript passages and VAD windows. Missing speech must remain discoverable.
4. Speaker identity is distinct from transcript accuracy, speech activity, and timing accuracy. Record uncertainty separately for each.
5. Keep overlapping speakers representable. Silence, audible but unintelligible speech, uncertain identity, and excluded evaluation regions are separate states.
6. Stable dataset person IDs survive regrouping. Teacher-local speaker IDs are namespaced by run and recording and never treated as global identities.
7. Human corrections are immutable events with reversible revisions. Derived annotations can be rebuilt; reviewed truth cannot be silently overwritten by a rerun.
8. Freeze evaluation splits before comparing candidates. Keep teacher labels, reviewed references, training corrections, and sealed test labels separately addressable.

## Stage 0 — read-only inventory and isolated capture

Read repository instructions, `docs/writing.md`, the library design, and the preparation practice in `docs/worklogs/2026-10-21-people-review.md`. Inspect current storage and snapshot code before implementing a new exporter. Reuse safe preparation logic where suitable, without importing candidate predictions as truth.

Inventory completed recordings from the main library read-only. Exclude active capture, incomplete finalization, and recordings changing during capture. Copy selected audio and minimal timing metadata using independent APFS clones or copies; never symlink or hard-link to the live library. Use a consistent database snapshot if needed, check source transactions and file hashes/metadata before and after capture, and discard inconsistent snapshots. Preserve source audio bytes as the recovery baseline.

Select two or three *whole* completed meetings, preferably 8–12 minutes each. Aim for varied voices and conditions: a relatively clear conversation, a multi-speaker meeting, and mixed-language or overlapping speech if available. Choose using duration and descriptive metadata, without selecting only examples favorable to a candidate. Document the selection rule and omissions privately.

If suitable whole meetings do not exist, report the available durations. Ten-minute excerpts are an explicit fallback, labeled as excerpts with original offsets and source meeting IDs. They cannot stand in for the later long-context validation. Prevent excerpts from the same meeting crossing evaluation partitions.

Stage output: private capture manifest with opaque recording IDs, source hashes, durations, sample rates, channels, track offsets, missing spans, capture consistency evidence, and source-to-derived audio maps. Record only aggregate counts in tracked reports.

## Stage 1 — reproducible teacher baseline

### Audio preparation

Preserve originals. Create one deterministic, lossless teacher input per meeting with a recorded channel/mix policy, resampling implementation, gain policy, and hashes. Account for separate microphone/system clocks, offsets, discontinuities, and duplicated remote audio/echo. Do not assume one track equals one person. Verify a few synchronization landmarks and channel transitions before inference.

Both teachers receive the same canonical content where their supported formats permit. Any format differences must decode to equivalent samples or be recorded as an experimental difference. Do not trim silence, denoise, concatenate speech, separate voices, or alter context in the baseline. These can change speaker decisions. Retain independent original tracks for adjudication.

### VibeVoice-ASR

Use the official offline ASR model and implementation, not a similarly named TTS or streaming checkpoint. Pin model revision, weight hashes, code commit, container digest, dependencies, CUDA/runtime, GPU, numeric precision, attention implementation, decoding settings, seed, prompt, and input hashes. Record licensing information.

Start with the official supported inference path, one worker and one meeting at a time. Fix decoding settings and avoid speaker names or candidate transcripts in prompts. Validate structured output, truncation, speaker count, timestamp bounds, repetitions, and omissions. A successful process exit is insufficient.

### pyannote commercial

Select the exact commercially available model after the user's account is ready; record its identifier/version and all request parameters. Do not silently use a changing default model. Preserve service request IDs and raw responses. If an immutable backend revision is unavailable, record the limitation and archive responses as the reproducibility boundary.

Do not provide a speaker count inferred from the competing app or VibeVoice baseline. Keep any later known-speaker-count experiment separately identified. Preserve overlap-aware output when available; an exclusive transcript alignment view is a separate derived artifact.

Stage output: immutable raw teacher responses, normalized proposals, validation reports, resource receipts, and explicit incomplete/failed states. Pending pyannote access must not be replaced with fabricated consensus or hold up VibeVoice preparation.

## Stage 2 — resource measurement and cost controls

Do not pick a GPU solely by its hourly price. Compare total cost per completed audio hour, including setup, model loading, idle time, failed attempts, storage, and transfers. Capture the current quoted rate and currency before allocating compute; prices in web documentation are not a run receipt.

Implement a configured monetary ceiling, worker-count limit (initially one), wall-clock deadline, bounded retries, and independent cleanup/watchdog behavior before launching a paid run. The user has authorized using credits but has not supplied a dollar ceiling. Prepare the concrete pilot estimate and ask for that missing ceiling before paid provisioning; do all local preparation first. Do not treat the full credit balance as a budget. Reuse the approved ceiling for subsequent work within scope rather than repeatedly requesting approval.

| Measurement | Required evidence |
| --- | --- |
| Audio work | Original/canonical seconds, channel count, bytes, chunk count |
| Timing | Queue, provisioning, download, cold load, preprocessing, inference, output validation, upload/download, cleanup |
| Compute | GPU model/count, peak allocated/reserved VRAM where available, sampled GPU memory/utilization, peak host RSS, CPU use |
| Billing | Quoted rate, allocated/billed duration, compute/storage/transfer amounts, failed-run charges, credits consumed, reconciled provider charge |
| Efficiency | Inference real-time factor, end-to-end seconds per audio hour, cost per successful audio hour, cold and warm runs separately |
| Quality | Output equivalence, output validity, missing/truncated intervals, audit findings |

Use monotonic timing. Record the GPU sampling interval; sampled memory peaks are lower bounds. Distinguish measured costs from rate-based estimates and missing counters. Include the pyannote service cost and local preparation cost separately; provider GPU memory may be unavailable.

Cleanup must run after success, error, timeout, cancellation, and local controller failure. Persist resource IDs before submitting jobs. On resume, reconcile existing remote jobs before creating another. Stop/delete billable compute and unneeded storage according to the verified provider lifecycle, and confirm its remote state. A canceled request or disconnected client does not prove billing has stopped. Never delete unrelated account resources.

## Stage 3 — optimization with an explicit equivalence gate

Run the unoptimized baseline twice on at least one pilot recording to measure inherent repeatability. Preserve both outputs. Compare normalized speaker assignments after optimal speaker-ID permutation, exact boundaries, transcript text, segment structure, and missing regions. Preserve raw byte hashes separately; request IDs and serialization differences do not constitute semantic changes.

First optimize work that should not change inference: cache checksummed weights, reuse the loaded model across files, prepare identical audio locally, avoid repeated transfer, and checkpoint completed outputs. Measure cold and warm costs separately.

Test one change at a time. Different GPUs, kernels, precision, batching, vLLM, quantization, decoding, shorter chunks, or source separation can alter predictions. They are candidates requiring equivalence checks, not automatically safe optimizations.

An execution optimization may replace the baseline only if every pilot recording passes exact normalized-output equivalence and no source content is lost. Record timing and speaker-partition differences, even if tiny. If the baseline itself is nondeterministic, report that limit and retain the reference output; do not redefine “same results” as similar aggregate accuracy. Approximate equivalence requires a separately agreed tolerance and must be labeled accordingly.

The official vLLM path is worth benchmarking after the baseline. If it changes outputs, retain it as a separate teacher configuration rather than overwriting reference annotations. Prefer the least expensive configuration that passes the defined gate, rather than the fastest configuration regardless of cost.

Stage output: baseline-versus-optimization matrix with cost, runtime, memory, repeatability, and exact-equivalence outcomes. Stop ineffective optimization attempts within the budget.

## Stage 4 — reference reconciliation and minimum-effort review

Normalize teacher proposals to overlapping time intervals on the canonical recording timeline. Align arbitrary teacher speaker IDs through duration overlap for comparison; preserve ambiguity and unmatched speakers. Alignment is a comparison operation, not proof of identity. Flag suspicious speaker collapse and fragmentation even if global overlap mapping looks strong.

Maintain three distinct layers:

| Layer | Content | Permitted use |
| --- | --- | --- |
| Teacher proposals | Raw and normalized predictions from each model | Candidate training proposals and disagreement analysis; never claim ground truth |
| Provisional reference | Agreement regions plus unresolved conflicts and provenance | Exploratory agreement metrics and review prioritization |
| Verified reference | Human-audited intervals with explicit speaker/overlap/timing decisions | Primary benchmark scoring and correction-replay labels |

Review queues must include teacher disagreement, suspected missed speech, new/rare voices, short turns, overlap, boundary problems, cross-meeting matches, and a random sample of teacher agreement. Agreement can share systematic errors. Save sampling strata, inclusion probabilities where applicable, and random seeds. Report targeted-audit and random-audit results separately; a disagreement-only sample cannot estimate library-wide accuracy.

Present synchronized source audio and concise choices: Same Person, Different People, Correct Person, Multiple Voices, Unclear, and boundary adjustment. Permit anonymous stable identities. Hide model/configuration identity during initial adjudication where practical. Provide context playback, source-track selection, one active player, exact time navigation, keyboard actions, Undo, draft recovery, and stable links. One verified interval or identity relationship applies to every evaluated configuration. Never ask the user to repeat the same correction for each model.

For the pilot, fully audit a small preselected contiguous block from each meeting in addition to targeted cases, so missed speech and boundary errors are visible. Begin with approximately two minutes per meeting and expand if errors remain frequent; this is an initial workload target, not a statistical guarantee. Audit all available voices through representative contexts. Log reviewed duration, actual review time, unresolved cases, and corrections per audio hour.

Cross-meeting identity requires separate evidence. Suggest matches using multiple clean contexts and independent matching evidence where available; confirm representative links and audit contradictions. Avoid circularly using the encoder under evaluation as the sole identity oracle. Keep uncertain links unresolved. A name on one clip does not verify all members of its machine cluster.

## Stage 5 — versioned data contract

Implement validated schemas before bulk inference. Keep these logical entities separate; the implementation may use JSONL plus indexed views:

- Recording: opaque ID, source/canonical hashes, duration, channels, timeline map, snapshot provenance, capture date, partition.
- Teacher run: model/code/container revision, settings, prompt hash, input hash, request/resource IDs, lifecycle status, resource/cost receipt, raw output path/hash.
- Proposed interval: run ID, recording ID, start/end, teacher-local speaker ID, speech/overlap status, transcript and timing granularity, reported confidence with its original meaning.
- Reviewed interval: stable annotation ID, recording/time bounds, zero/one/multiple person IDs, intelligibility, uncertainty per dimension, evaluation eligibility, provenance, revision.
- Identity relationship: same/different/unknown, exact evidence references, reviewer decision, scope, revision; consistency checks prevent contradictory merges.
- Annotation event: operation, prior revision, affected evidence, timestamp, reversible payload, reviewer identifier; distinguish explicit decisions from propagation.
- Release manifest: schema/version, source and artifact checksums, partition map, annotation revision, scoring policy/version, quality report, exclusions and reasons.

Use finite half-open intervals in seconds with a declared precision and source sample mapping. Validate bounds, track offsets, duplicate inputs, missing media, impossible references, and contradictory labels. Preserve simultaneous speakers instead of forcing a single label. Never fabricate word/character times: store native timing granularity and provenance for any later forced alignment.

Exports: overlap-capable RTTM for diarization, structured identity/event data for global association and replay, and UEM-style scored regions for partial annotation. RTTM alone cannot express the entire reference contract. Keep raw artifacts immutable; publish new dataset versions when annotations change. Do not overwrite old benchmark inputs.

## Stage 6 — full-meeting expansion

Pilot meetings are development data. Their success does not validate hour-long inference. Before bulk processing, run one medium and one long completed meeting, measuring memory, context/token limits, omissions, speaker drift, and cost. Then expand to a selected snapshot of the latest 20 completed meetings, followed by broader main-library cohorts if needed. Exclude active/incomplete meetings at each snapshot.

VibeVoice's published single-pass context supports up to 60 minutes subject to token/context limits. Do not assume every recording under that duration fits. Detect limits before submission and detect truncated outputs afterward. For longer recordings, define overlapping chunks on the original timeline, retain duplicate overlap as reconciliation evidence, and verify speaker continuity across joins. Chunk-local IDs require explicit reconciliation. Do not silently concatenate chunks or count duplicate speech twice. Compare chunked and full-context outputs on recordings where both are possible; changed context is a methodological change, not a result-preserving speed optimization.

Forecast full cost from measured fixed startup cost plus duration-dependent work, retry allowance, and retained storage. Report an estimate range and remaining approved budget before each batch. Stop before exceeding the configured ceiling; request only a required budget increase. Keep batches resumable and outputs content-addressed so re-running the controller does not re-bill successful work.

## Stage 7 — freeze the benchmark and correction-replay protocol

Split by whole meeting/session and time, with duplicate audio detection across splits. Keep pilot/tuning meetings separate from held-out evaluation. Include future sessions of known people and an unseen-person cohort; verify that unseen identities do not appear in enrollment/training evidence. Where identity uncertainty prevents such a claim, report the limitation.

Freeze the audited reference and partitions before choosing candidate settings. Report:

- Speaker-confusion, missed-speech, and false-alarm durations, plus DER with documented overlap and boundary-collar policies. Show strict scoring and a declared tolerance view separately.
- Cross-meeting false merges, false splits, unknown-person errors, and unresolved coverage. Unassigned speech must affect coverage/error; it cannot silently disappear from the denominator.
- Per-meeting results, duration-weighted aggregate, equal-meeting aggregate, difficult-meeting tail, and uncertainty estimated by resampling meetings rather than correlated adjacent windows.
- Human review minutes, correction count, reference audit error, and teacher-only versus verified evaluation coverage.

For association, use one consistent global identity mapping or enrolled known IDs; per-meeting remapping would hide global identity failures. For local diarization, document the recording-local mapping. On partial gold, score only explicitly verified regions and disclose coverage; do not generalize targeted review scores to the full library.

For later learning experiments, replay identical eligible correction events in identical orders at fixed budgets. Evaluate on unconfirmed held-out sessions with labels inaccessible to the learner. Keep prototype-only, constrained clustering, contrastive, prototypical, and hybrid methods separate. Never train on the test reference or choose subsequent correction queries using hidden test identities. Reusing the same exposed test set repeatedly creates selection bias; reserve a final untouched cohort for future decisions.

## Implementation order and acceptance gates

1. Build schemas, safe capture, manifest validation, and synthetic fixtures. No paid resources needed.
2. Build resumable provider adapters, lifecycle journal, cost limits, cleanup, and mocked failure tests. Prepare the concrete pilot estimate and obtain the missing budget ceiling.
3. Run the 2–3 meeting VibeVoice baseline. Add pyannote when access arrives. Preserve partial progress if one provider is unavailable.
4. Measure repeatability and bounded result-preserving optimization. Complete an independent review of resource cleanup and reference normalization before expansion.
5. Build reconciliation and minimal shared review. Audit pilot labels and timing. Report measured teacher errors and remaining uncertainty.
6. Validate medium/long meetings and chunk joins, forecast full cost, and expand within budget.
7. Freeze a versioned verified release with reproducible scoring, documented splits, and a checksum manifest.

Required failure tests: interrupted upload, timeout, out-of-memory, malformed/truncated response, lost connection after accepted job, duplicate invocation, controller restart, missing response, retry budget exhaustion, stale annotation edit, failed cleanup, and credential redaction. Test normalization and scoring with synthetic arbitrary speaker permutations, overlaps, missing speech, empty output, drift, chunk boundaries, and cross-meeting identity conflicts.

Release gates: complete lineage for every included label; validated timelines and audio hashes; no hidden duplicate leakage; explicit gold/provisional separation; successful scoring round-trip; completed random and targeted audits with denominators; frozen partition and scoring definitions; reconciled billing or clearly identified outstanding charges; zero unexplained active resources. A dataset can release an explicitly limited verified subset while other regions remain provisional.

## Next-agent handoff

Read this plan and README first, then repository instructions and the referenced snapshot worklog. Work directly on master and preserve unrelated changes. Keep the current reviewer and its judgments untouched. Do not commit private data or secrets. The user will run the implementation agent separately; no worker or paid job has been started by this planning task.

Use the app `.env` only as an authorized local source for the required Runpod key; parse it without shell-evaluating arbitrary file contents. Discover the variable name without printing values. Never transmit the Runpod key to an untrusted model container. Keep provider administration on the controller, using separate limited job inputs for workers.

First deliverable: a reproducible local inventory and pilot selection, schema tests, provider execution/cleanup design, and a rate-based pilot estimate. Then execute the staged plan. Add actual tested commands to README and maintain RESULTS as one coherent report. Report blockers precisely: pyannote credentials and a numerical spending ceiling are currently pending. All other local preparation can proceed.

## References

- [Microsoft VibeVoice repository](https://github.com/microsoft/VibeVoice): official ASR implementation and supported inference paths. Pin the actual revision used; do not reuse TTS requirements as ASR estimates.
- [VibeVoice-ASR model card](https://huggingface.co/microsoft/VibeVoice-ASR): long-form speaker-attributed transcription and advertised context capability. Meeting-specific label accuracy remains to be measured.
- [pyannote benchmark](https://www.pyannote.ai/benchmark): diarization evaluation and vendor results. The selected commercial model and service revision must be recorded at execution.
- [Runpod pricing](https://www.runpod.io/pricing) and [billing documentation source](https://github.com/runpod/docs/blob/main/serverless/pricing.mdx): distinguish provider billing from useful inference time and obtain a current quote for each selected resource.
- [Existing library design](../../docs/design/2026-10-24-voice-recognition-library.md): durable identity decisions and evidence provenance.
- [Existing clustering experiment](../global-voice-clustering/README.md): candidate systems to evaluate; their outputs are not reference labels.

References checked October 26, 2026. Published capability and price information is a planning input, not a measured outcome of this experiment.
