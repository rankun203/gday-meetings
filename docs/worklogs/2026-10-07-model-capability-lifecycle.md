---
title: Model capability lifecycle
date: 2026-10-07
status: in-progress
scope: swift-model-resources
---

# Model capability lifecycle

## Problem

Availability checks could hash large model assets. Acquisition could validate by loading temporary models, then load fresh instances for processing. Search loaded at startup, saved voice examples repeatedly created workers, and automatic semantic indexing could contend with live capture. Retired CLSP code remained in the app.

## Implemented solution

`LocalModelManager` separates metadata-only availability, shared temporary provider validation, and processing acquisition. Successful verification receipts bind the manifest revision and exact file identity, including inode and change time. Changed files are verified again. Trusted hard-link operations preserve receipts when only change time changes. Subset materialization keeps Community-1’s full receipt and writes a separate destination receipt. Removal reserves the model before yielding; cancellation releases reservations without reporting a model failure. Counters report verification passes, bytes actually hashed, preparation attempts, successful graph loads, and preparation elapsed time.

Provider settings publish checking and completed validation together. General and feature controls continue to use availability estimates. Apple transcription uses its existing asset checks and opens no analyzer for health. Temporary local validation resources are released. Processing workers own independent leases rather than sharing mutable model instances.

Search preparation starts with the first nonempty edit. Subsequent edits and Enter reuse it. Query and indexing sessions have separate generations, preparation tasks, graphs and resource ownership. Index scans do not keep passage resources resident; idle indexing resources are released. Configuration changes, capture suspension, library changes and shutdown cancel or retire owned work. Shared preparation propagates cancellation to its worker, including while maintenance admission is suspended. Shutdown detaches all query, index and scan state before waiting; a subsequent request does not reuse a canceled preparation, and old retirement cannot unload replacement resources.

Find Voices owns reusable discovery and embedding sessions across bounded inputs. Discovery leases retain their acquiring manager for release, even if the shared manager is replaced. Replacement runs install cleanup before awaiting old sessions so repeated pause/cancel cannot retain completed retirement tasks. Progress and recovery remain per input. Sessions finish after success, failure or cancellation; retiring runs remain joinable and a replacement run awaits their cleanup. Starting capture blocks new maintenance and processing admission, pauses voice jobs, and retires background work without waiting to begin audio capture. The Tasks agent’s shared coordinator supplies bounded, prioritized resource admission and a reserved capture slot. Automatic indexing records changed-content intent during capture and scans finalized content afterward. The existing two-second coalescing and task deduplication were retained; the implementation does not assume a new task for every transcript line.

CLSP runtime, registry, preprocessing, voice index, fixtures, tests and app packaging references are removed. Pure retired configurations are disabled. Explicit Granite configurations survive leftover subprocess fields. After the first frame, an owned background migration removes only retired tables, registrations and the retired provider’s derived embeddings. Opening an index performs no destructive retirement work. Empty libraries need no database or meeting directory for cleanup. Retired weights are removed from the active model folder, along with inode-matched cache objects whose last link belongs to that retired installation. Shared Community-1 links and all source meeting, transcript and people data are preserved. The user subsequently required deleting all historical CLSP code, designs, experiments and documentation. The reference worker and dedicated designs were deleted; mixed retrieval experiments retain only non-CLSP methods and results. Granite conversion tools live under `tools/semantic-model-conversion`. Existing worklogs were explicitly exempted from removal.

## Reasoning

Availability is an estimate, so actual acquisition handles missing files and runtime failure. Identity-bound receipts avoid repeated hashing without treating a filename or modification date alone as proof. The first use after upgrading ignores old `.gday-prepared` receipts and creates the new receipt after verification. This can require one initial verification/preparation.

A lease reserves assets while its worker uses them. Additional long-query graph preparation belongs to the query worker and participates in manager counters and cleanup. Provider-page validation can load temporarily; feature readiness does not require opening that page first.

General settings was inspected in the isolated transcript Preview before editing. The design removes the obsolete Automatically Load Search switch and its explanatory text, retaining the native settings layout and surrounding Appearance controls. Provider pages retain their controls while consuming stronger validation results separately.

## Validation

The focused full-Xcode run passed 51 tests across six suites in 8.965 seconds. After the final cleanup changes, 42 lifecycle tests across five suites passed in 0.709 seconds; a subsequent four-test cleanup run passed in 0.063 seconds. The retained retrieval experiment suites passed 34 tests (10 retrieval, six expansion, 11 reference review and seven ASR). Python syntax checks and `git diff --check` passed. Deterministic regressions cover full/subset receipt coexistence, trusted link changes, cancellation while maintenance admission is suspended, removal-before-acquisition ordering, semantic configuration preservation, and CLSP source/shared-object preservation. Search tests cover typing/Enter preparation reuse, query/index separation and configuration retirement; a fake voice job checks session reuse across three inputs and cleanup after failure. Cancellation fixtures wait for cancellation rather than relying on a short deadline.

The opt-in `ModelLifecyclePerformanceTests` sample uses an 8 MiB synthetic asset and a mock preparer. Run with `GDAY_MODEL_LIFECYCLE_PERF=1` and filter that suite. One isolated run measured 100 availability checks at 12.395 ms wall time, 1.358 ms main-thread CPU and 11.289 ms process CPU. Process physical footprint changed from 20,808,352 to 21,037,728 bytes. Two acquisitions verified the asset once and prepared two independent sessions. Their 0.109875 seconds of preparation time includes two deliberately simulated 50 ms waits. This sample loads no Core ML graph and measures neither recording responsiveness nor GPU/ANE use.

The first isolated release passed in 215.02 seconds with macOS 26.0 minimum, SDK 27.0, and strict signing. Its copied build cache emitted stale-path warnings, requiring fresh compilation; these were not source deprecation warnings. The final combined release passed in 193.20 seconds, with macOS 26.0 minimum, SDK 27.0 and strict signing. The uniquely identified synthetic Preview (`com.gdaymeetings.macos.preview.lifecycleafter`, visible provenance `lifecycle-after-198abb5`) was inspected after implementation: General no longer contains Automatically Load Search, and the surrounding Appearance and Display Summary Title controls retain the native layout. General readiness and provider repair links remain visible for missing assets. No installed model was loaded for this UI check; live provider validation remains covered by synthetic lifecycle tests. The Tasks agent owns the separate after-state Tasks interaction check. No source deprecation warnings appeared in the final release log. Existing running bundles and private libraries were preserved.

Default Claude Code used `claude-opus-5-5[1m]` for the completed read-only review. It found the subset-receipt, suspended-preparation cancellation, removal race, indexing generation/lifetime, configuration migration and trusted-link issues addressed above. The follow-up review was blocked by Claude’s monthly spend limit. Parent-agent independent review subsequently found canceled replacement-run cleanup, discovery lease-owner and shutdown preparation reuse issues. These were repaired with deferred token cleanup, retained lease ownership and synchronous generation detachment. The first focused regression run passed 18 tests in two suites in 0.594 seconds. The final gated regression verifies that old shutdown retirement leaves replacement query and index resources loaded; all 19 focused voice/search tests passed in 0.608 seconds. The parent completed independent review and the installed-model measurement below. The final combined isolated release passed in 183.63 seconds with macOS 26.0 minimum and SDK 27.0; strict signature verification passed, and the checked source tree matches the release snapshot. Full Xcode emitted no source or deprecation warnings. The integrated serialized suite passed all 1,063 tests across 183 suites in 107.907 seconds. The Tasks worklog records the cross-test AppKit starvation diagnosis and runner correction. Hardware performance acceptance remains limited as described below.

### Installed-model validation

The parent independently reviewed acquisition, validation receipts, search generations, job ownership, cancellation, recording deferral, and retired-data cleanup. The three additional ownership/cancellation repairs above passed their gated regressions. Historical worklogs retain their original paths and content; removed runtime code is not relocated into an archive.

`InstalledModelLifecyclePerformanceTests.nativeQueryPreparationAndRelease` exercises the actual Granite 97M Core ML graph using copied installed assets and synthetic text. Set `GDAY_INSTALLED_MODEL_SOURCE` to an installed `LocalModels` directory and filter that suite. The test writes only to a fresh temporary copy and removes it afterward. It neither reads meeting content nor downloads assets. Availability checks must perform zero hashing and graph loading; repeated queries must reuse one preparation; six prepare/release cycles must verify files once and end with zero leases.

The final Debug run on macOS 26.6.2, Apple Silicon, Swift 6.4 and SDK 27 passed in 29.447 seconds. Counters record successful Core ML graph loads, not inferred CPU samples. Phase costs include asynchronous waiting; reload rows below include a deliberate one-second settling interval. Other test activity ran on the machine, so these are diagnostic observations, not a matched speed comparison or release latency claim.

| Operation | Wall time | Main-thread CPU | Process CPU | Cumulative graph loads |
| --- | ---: | ---: | ---: | ---: |
| 100 availability checks | 106.65 ms | 2.37 ms | 97.28 ms | 0 |
| Initial query preparation and warmup | 4.945 s | 1.86 ms | 4.717 s | 1 |
| Five synthetic queries | 34.62 ms | 0.49 ms | 23.01 ms | 1 |
| Cached provider validation after release | 2.79 ms | 0.18 ms | 2.75 ms | 1 |
| Five further prepare/query/release cycles | 4.80–4.90 s each | 0.29–0.39 ms each | 3.70–3.80 s each | 6 |

The run hashed 222,562,676 bytes once. Every release reduced the manager's lease count to zero. Process physical footprint was 9.1 MB before preparation, 316.6 MB after preparation, and 383.2–412.5 MB after the later release cycles (decimal MB). Releasing owned graphs did not restore the initial footprint. This short run does not establish a memory plateau or identify runtime caches versus allocator retention; an allocation/VM capture is needed before claiming all model memory returns. It does rule out another model load for each of the five queries within one session. CPU counters exclude GPU/ANE attribution and do not measure presented frames or live capture contention.

The Command Line Tools Debug link emitted existing missing-search-directory warnings for `Developer/usr/lib` and `Developer/Library/Frameworks`. No deprecation warning appeared. Final release validation uses full Xcode; no warning suppression or source workaround was added.

## Technical debt

FluidAudio’s public offline processing call exposes no asynchronous admission boundary within one recording. Canceling a whole-recording discovery or labeling call can therefore retire it only at the next dependency cancellation boundary. Reserved capture admission and blocking new processing avoid making audio start wait for that call, but do not prove accelerator contention is eliminated. Measure live capture alongside an already-running offline operation; if the result is unacceptable, introduce supported chunk-level cancellation/admission in the dependency rather than modifying its cached source.

The preexisting legacy Application Support import preserves its original source folder. Active-library CLSP resources are retired; historical source-cache cleanup remains a separate stopped-app storage cleanup. No retired runtime compatibility bridge remains in the app.

## Notes

Installed Granite query load counts, preparation time, and process memory were measured above. Actual Find Voices throughput, retained-memory attribution, and capture/UI responsiveness still require Instruments runs with representative models and recordings. The tests do not attribute the earlier observed slowdown to a measured model operation. GPU and ANE attribution remains unmeasured.
