---
title: Audio analysis contracts
date: 2026-10-14
status: active
scope: macos-provider-contract
---

# Audio analysis

Version 1 separates recorded transcription and recorded diarization. Typed requests share request identity, provider identity, configured model, options, and immutable audio references. Alignment has a distinct request shape but no implemented adapter. Live transcription uses revision events. These contracts do not replace the durable remote submit, poll, and cancel transport.

## Audio and text

Each audio reference identifies a track, source category, audio revision, and recording offset in seconds. Intervals are half-open. Adapters normalize their timebase exactly once. Current recorded adapters support zero-offset whole files and reject unsupported offsets rather than applying them implicitly. Independent track identity remains available even when a track has no speaker label.

A timed text span identifies UTF-16 offsets in exact source text, its start and end, and timing granularity. Apple attributed runs may contain several words; remote aligned words are word-granularity only when supplied. Missing timing leaves explicit gaps. Invalid optional timing does not discard recognized text. Configured model selection is separate from a verified model revision.

Diarization returns acoustic intervals with speaker identifiers scoped to the result and track. Overlapping intervals are valid evidence. Typed embeddings and sample metadata are optional. A speaker identifier is not a People identity. Conversion into application speaker records happens after normalization.

## Capabilities and validation

Adapter capabilities describe implemented operations, timing granularity, speaker-count constraints, and timeline-offset support. They do not establish model readiness or guarantee that every output character has timing. Apple supports recorded and live transcription; Community supports recorded diarization. Remote worker transcription can include diarization, but the remote adapter does not advertise standalone diarization or alignment.

Requests reject unsupported versions, duplicate tracks, missing audio revisions, invalid offsets, and unsupported options. File revisions are checked before and after local analysis. Recorded output validates finite times and exact timing/text correspondence. Contract errors distinguish unsupported capability, invalid request, invalid output, and invalid stream revision. Existing provider transports retain their authentication and retry behavior.

## Streaming and switching

Each revision carries a session, epoch, sequence number, item identity, revision number, and provisional or final status. Duplicate delivery is ignored. Skipped sequence numbers require an explicit gap; a restart requires a fresh epoch. Finalized items cannot be revised in that epoch. Text finality does not imply final acoustic identity. Apple live transcription uses this validator; a universal live diarization adapter is not implemented here.

Provider selection applies to new requests. Admitted recorded requests retain their provider, configured model, language, options, and audio revisions. Existing pending remote jobs retain their original transport identity. Switching an active live provider requires draining or cancelling its session and recording the transition; changing a setting alone must not reinterpret existing events.

## Artifacts and publication

An immutable transcription artifact preserves original text and available timing. A diarization binding identifies the source transcription and acoustic result. The current transcript is a projection that may split or merge recognition rows around acoustic turns. Generated display separators are separate from source characters.

Source artifacts, transcript history, acoustic results, projection bindings, current transcript, and task receipts use the canonical transaction. Existing voice-example ingestion remains a separate persistence operation. Cancellation before publication keeps the current transcript. A local cancellation request does not guarantee remote work stopped; the existing transport reports acknowledgement and retains uncertain submission state to avoid duplicate paid jobs.

Legacy transcripts retain their available row timing and whole-row attribution fallback. They are not migrated into fabricated word alignment. Legacy pending requests without admitted audio provenance remain explicitly unknown. Manual edits or assignments that cannot be mapped safely remain intact; history restoration requires compatible source text, timing, track, and session. Alignment-only processing and full edit-operation replay remain unimplemented.
