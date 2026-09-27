---
title: A recent-word color trail in live transcription
date: 2026-09-27
status: implemented
scope: swift-app-live-transcript
---

## Evidence and design before implementation

Inspected timestamped frames from the supplied 13.41-second Voice Memos recording. The newest word is red and the preceding word is lighter red; earlier text is normal. The pair “word is” keeps the same colors across repeated frames at displayed recording times 15.59 and 16.10 seconds. When recognition advances, the colored pair moves to “and the”. Finalized text returns to normal with punctuation and earlier sentence corrections.

Replace the single-word approximation with this recognition-driven two-word trail. Blend the preceding word toward the normal text color; keep the latest word red. Recompute ranges from each replacement result, so sentence corrections cannot leave colors on stale offsets. Final results remove the emphasis. No frame timer or speculative elapsed-time fade is needed. Exact private Voice Memos interpolation is not established by the reference.

## Implemented solution

`LiveTranscriptPresentation` now returns the newest two word ranges from the current recognition text. `LiveTranscriptView` colors the newest red and mixes the previous word halfway toward the primary text color. It uses [SwiftUI’s public color mixing API](https://developer.apple.com/documentation/swiftui/color/mix(with:by:in:)); the installed SDK confirms availability from macOS 15. The blend is intended to match the reference visually; it is not an asserted private Voice Memos color constant. Existing final-result and disabled-state behavior removes emphasis.

## Validation

All eight presentation tests passed within the integrated 308-test suite. Formatting, lint, and the production build passed; the revised two-word colors have not been visually checked in dark/light appearance. The user is interacting with the validation app, so those checks are deferred without closing it. The supplied video is read only; no audio capture or upload is needed.

## Technical debt

The trail matches the observed two-word states, not an asserted reproduction of private Voice Memos animation internals. It uses public SwiftUI color mixing with a macOS 14 fallback; live recognition itself requires macOS 26.
