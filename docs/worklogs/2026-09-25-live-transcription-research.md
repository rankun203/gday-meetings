---
date: 2026-09-25
title: Voice Memos-style live transcription research
status: research-complete
scope: documentation-only
---

## Problem

Gday Meetings records microphone and system audio but transcribes completed files. A live transcript needs an engine choice, compatibility policy, safe capture integration, and durable handling of partial/final text. The user requested deep research, a worklog, and a committed/pushed report.

## Implemented solution

Added [live transcription research](../design/live-transcription-research.md), grounded in the Swift capture/store/model code, the existing server/worker contract, current primary-source documentation, and installed Speech SDK declarations. Compared SpeechAnalyzer/SpeechTranscriber, DictationTranscriber, SFSpeechRecognizer, WhisperKit, whisper.cpp, hosted streaming, self-hosted streaming, and short-file chunking. Included proposed architecture, timeline/revision rules, phased delivery, test gates, cost accounting, and unresolved experiments.

## Reasoning

Recommend an Apple on-device spike on supported macOS 26+ systems, preserving the app's macOS 14.2 minimum and existing batch transcription. The user's subsequent English/Chinese requirement makes the default conditional on English, Mandarin, and mixed-speech quality gates, with multilingual WhisperKit evaluated in the first stage. Apple identifies this API family as powering Voice Memos, but Voice Memos' macOS 15 requirement does not establish public API availability. Keep optional post-meeting alignment/diarization and preserve user edits across transcript revisions. A provider boundary allows later compatibility/cloud options without rebuilding capture.

Added a dedicated bilingual requirement, provider comparison, dialect/script distinction, proposed WER/CER/mixed-language thresholds, and routing policy. Mandarin is the planning baseline; Cantonese coverage remains explicitly separate. Source inspection found existing OpenCC script conversion and single-language batch alignment, while Swift submits `auto`; the report specifies settings/provenance and mixed-span alignment work rather than claiming those paths already satisfy bilingual support.

Current documentation revealed details worth avoiding stale assumptions about: WhisperKit's repository is now argmax-oss-swift; Whisper-Streaming points to SimulStreaming; OpenAI's current live-transcription guide has model-specific client-side turn commits and lacks word timestamps/diarization. SFSpeechRecognizer is not marked deprecated in the fetched metadata, but its documented duration/service limits make it a weak primary meeting engine.

## Validation

Reviewed source integration points and primary citations. Cross-checked macOS 26 availability, locale/assets, timing, and finalization APIs against Apple's documentation JSON and the installed Speech Swift interface. The bilingual follow-up checked current provider language/code-switching documentation and worker language/conversion/alignment code. Documentation validation covers relative links, balanced code fences, trailing whitespace, and the complete commit diff. No runtime code, dependencies, or schema changed; app builds and transcription benchmarks are not applicable to this research-only commit. Real accuracy, concurrency, resource use, and lifecycle behavior remain explicit implementation gates.

## Technical debt

None introduced by this documentation-only task. The report identifies existing implementation gaps rather than implementing shortcuts: batch completion overwrites the current transcript, segments lack word timing/provenance/revisions, and capture has no bounded ASR fan-out. Concrete remediation is included in the phased implementation plan; these gaps remain until that feature work is undertaken.

## Notes

Unrelated playback source/test edits and the adaptive-playheads worklog were already present and are excluded from this commit. No model downloads, provider inference, or private audio uploads were performed. The initial read-only Python documentation fetch hit the default uv cache sandbox restriction; rerunning with a temporary writable UV_CACHE_DIR succeeded. No compilation was run and no deprecation-warning-free build is claimed.
