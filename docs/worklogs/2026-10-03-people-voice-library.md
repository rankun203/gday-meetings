---
title: People voice library implementation
date: 2026-10-03
status: implemented
scope: swift-people-speaker-association
---

# People voice library implementation

## Problem

People did not expose voice evidence or support durable review. Speaker removal did not inform future matching, live profiles could change after an explicit assignment, and incompatible models lacked a reviewed-audio preparation path.

## Implemented solution

Implementation follows the [People voice library design](../design/2026-10-03-people-voice-library.md). Three sub-agents implemented evidence and corrections, local preparation and discovery, and People review. Integration covered playback, persistence, regression checks, and interface wording.

- People provides Review Voices, person-specific samples, suggested and unnamed groups, explicit selection, assignment, rejection, exclusion, grouping, and Undo. Timestamp links open the source recording; excerpt playback uses the shared transport and stops decoding at the selected boundary. Removed the redundant helper below Apply to This Speaker.
- A private, versioned `voice-library.json` retains source ranges, review decisions, compatible embedding representations, resumable jobs, and bounded review-only Undo history. Transcript assignment joins the existing file transaction. Saved review decisions replay onto fully enclosed transcript rows, with conflict handling and reversible projection.
- Confirmed, current, nonconflicting evidence builds model-specific profiles. New live samples remain unreviewed; automatic matches become suggestions instead of transcript names. Rejections suppress similar suggestions without changing other confirmed assignments. Legacy vectors without exact playable evidence do not train profiles.
- Local preparation reuses compatible vectors or extracts bounded excerpts. Discovery inventories recordings in pages and analyzes one recording at a time without replacing transcripts. Jobs retain progress, support pause/retry, recover paused after restart, validate source revisions, and avoid duplicate replay. Existing evidence must cover all saved speakers and audio sources before discovery skips analysis.

## Reasoning

Reviewed audio is durable evidence. Embeddings are model-specific representations, and profiles can be rebuilt from confirmed examples. Uncalibrated automatic matches remain suggestions rather than appearing as confirmed people. Providers with identical extraction contracts reuse embeddings; provider configuration IDs do not define compatibility.

## Technical debt

- The atomic sidecar rewrites the current evidence and job snapshot on each checkpoint. This keeps decisions and recovery state together, but creates write amplification for large voice libraries. Move evidence and jobs to independently persisted records with a disposable index before large-library scale demands it; Undo already stores review metadata rather than repeated vectors.
- Audio revision checks use size and modification time so review does not hash hours of audio on the main actor. A timestamp-preserving same-size replacement can evade this check. Add a background content digest and migrate revision receipts for stronger replacement detection.
- Legacy vectors remain reviewable but cannot establish trusted enrollment. Older clients ignore the new sidecar and cannot enforce its corrections; the updated client replays them. A future library-format gate should prevent older writers from bypassing this contract.
- Transcript rows crossing a reviewed excerpt boundary retain their existing assignment. Splitting text without word timing would invent boundaries; add word-aligned correction projection when supported by the transcript representation.
- RunPod lacks a declared compatible extraction adapter. Local preparation works now; remote preparation requires a versioned extraction contract and explicit upload flow. Held-out false-alarm evaluation and per-space score calibration remain prerequisites for automatic identity assignment. Synthetic tests establish behavior, not biometric accuracy.

## Notes

The existing People screen was captured and inspected before UI changes. Validation uses synthetic examples and isolated libraries. No production voice samples or recordings are modified by implementation validation.

Formatting and lint passed; the complete serial Swift suite passed **758 tests in 131 suites**. After the last review, **14 core tests and 36 related regression tests** passed, including two added regressions for bounded Undo notifications and saved-vector provenance after audio replacement. Coverage includes atomic rollback, durable rejection, Undo, exact-range projection, changed audio, incompatible models, pause/recovery, partial recording coverage, a 1,000-recording descriptor inventory, bounded conversion, and offline render verification that playback emits no speech past the excerpt boundary. Parallel full-suite attempts encountered timing-sensitive failures; the serial run passed without changing those test timeouts. SwiftPM required the authorized non-nested-sandbox invocation.

Isolated release Preview checks covered light and dark appearances, person samples, the review filters, excerpt playback, timestamp navigation, selected-example assignment without confirming the rest of its group, rejection, Undo, group merge and Undo, and provider empty-state controls. The review sheet remained usable when opened from a narrower parent window. The person details panel still has a tall minimum content requirement; small-height layout and real model/hardware behavior remain validation limits. Assignment review found and fixed singular wording, full-row click targets, and Return-to-assign behavior.

The final `make build-macos` release passed in an isolated checkout (149.26 seconds), including app packaging and signing. The packaged build was reopened to verify the corrected assignment title, focused search, Return-to-assign, and resulting Named entry. Toolchain linker warnings reference absent Command Line Tools `Developer/usr/lib` and `Developer/Library/Frameworks` search paths; these are not deprecation warnings. No real model accuracy evaluation, remote extraction, or live hardware capture test is claimed. Local model discovery tests use controlled extractors and synthetic audio.

The complete source and documentation diff was reviewed before committing. Remote macOS matrix status is checked after pushing and reported separately.
