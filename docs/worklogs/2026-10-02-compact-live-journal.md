---
title: Compact live transcript journal and Meetings title
date: 2026-10-02
status: validated
scope: swift-live-transcript-storage-and-ui
---

# Problem

The live journal repeatedly serialized speaker metadata, embeddings, and manual overrides in state events. Field-name overhead also increased transcript event size. The Meetings toolbar repeated the sidebar section name without the app's identity.

# Implemented solution

- New live recordings write version 2 CSV transactions. Phrase and word rows use fixed columns, short source and event codes, and dictionary references for UUIDs. Speaker definitions and manual overrides are written only when changed. State rows contain changed values instead of complete repeated drafts.
- Each transaction ends with a row count and SHA-256 of its original bytes. Recovery validates committed transactions, ignores incomplete tails, and restores dictionaries before resumed appends. Queue limits, file privacy, failure reporting, and the completed snapshot digest remain in place.
- Recovery reads only CSV event journals. Old JSONL event files are ignored and left untouched, as requested. Completed CSV journals move to `.saved.csv`; completed live snapshots retain their existing JSON schema. No event format auto-detection or fallback remains.
- The generated library guide explains the CSV schema, integrity checks, replay semantics, and file authority. Startup appends the versioned section to existing ordinary guides while preserving custom content. Read-only calls and symlink guides remain untouched. The current library guide also received the section directly.
- The supplied before screenshot shows a plain Meetings title beside the sidebar toggle. The intended design puts the existing koala logo and “Gday Meetings” in that same toolbar item, with a six-point gap and the existing headline font. The logo is decorative for accessibility; other destinations retain their section titles. No new control or recording behavior is introduced.

# Reasoning

Removing repeated state yields larger savings than replacing JSON punctuation alone. CSV holds the frequent text and timing fields directly. Optional phrase attributes, speaker records, begin metadata, and override objects use quoted JSON cells to preserve their existing typed schemas without inventing a parallel model. These cells are explicitly documented. Logical transactions retain complete phrase/word groups after a crash. Existing in-memory stream behavior remains the authority for overlap replacement and effective speaker attribution.

# Technical debt

- Recovery still loads the journal and reconstructed records synchronously through the existing document loader. This can delay opening a long interrupted recording. A future asynchronous streaming recovery path should replay committed events without retaining the full record array.
- Speaker objects are deduplicated as complete typed values. A changed embedding rewrites that speaker object, and state comparison still inspects current speaker metadata and overrides on the utility queue. Measure this CPU cost before introducing per-field dirty tracking.

# Validation

The final serial run passed 701 tests in 119 suites in 68.03 seconds. Coverage includes replay equivalence at every event prefix, Unicode and multiline CSV, every-byte interrupted writes, checksum corruption, resumed dictionaries, explicit clears, state size bounds, snapshot authority, guide preservation, ignoring old JSONL files without modifying them, and existing controller finalization. A repeated synthetic state event remains below 180 bytes, over 95% smaller than the equivalent synthetic JSONL state. This is a fixture result, not a measured compression ratio for the user's recording.

Formatting, lint, and whitespace checks passed. The final CSV-only `make build-macos` release build passed in an isolated checkout in 144.91 seconds, including property-list and code-signature validation. The active app and its recording have not been restarted or replaced.

The supplied before screenshot and isolated production-UI Preview were compared. The branded title passed light, dark, and system appearance checks, including active and inactive presentation, a narrower window, keyboard sidebar collapse/expansion, and switching to People and back. The accessibility tree exposes one “Gday Meetings” text element and hides the decorative image. The UI code was unchanged by the subsequent CSV-only recovery adjustment. A full VoiceOver session, actual audio capture, and real-recording recovery were not exercised; synthetic replay and controller tests cover storage behavior.

The CSV quoting check operates on UTF-8 bytes so CRLF is quoted even though Swift treats it as one Character. Separate cases cover CRLF, CR, LF, empty text, quotes, and Unicode. Typed voice-vector values and clearing an embedding also passed focused replay checks.

The release toolchain reports the existing missing `/Library/Developer/CommandLineTools/Developer/usr/lib` and `Developer/Library/Frameworks` linker search paths. No new API deprecation was reported. The [existing toolchain follow-up](2026-09-30-macos-release-ci.md) is to update or repair Command Line Tools; the app does not suppress these diagnostics. The user requested publication after validation. Commit and push include only this task’s changes; unrelated endurance work remains in the working tree. The production app has not been installed or restarted. Hosted macOS CI results will be checked after pushing.
