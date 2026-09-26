---
title: One transcript workspace for live and saved text
date: 2026-09-26
status: in-progress
scope: swift-app-transcript-ui
---

## Problem and before screenshots

The supplied recording screenshot was inspected before editing. Live text nested its scrolling area inside the recording card’s settings scroll area, so following text could move the live control under the meters. A separate before screenshot of Preview’s saved Transcript tab showed timestamped, editable rows but no direct re-transcription action above them.

## Design before implementation

Follow [the transcript workflow](../design/transcript-workflow.md). Move live text into the Transcript tab, with the live switch, status, and Follow Live action outside its single scrolling viewport. Reuse the saved transcript row spacing, timestamps, and dividers. Show track names only as secondary source descriptions, never speaker identities. Partial text stays visually provisional; scrolling earlier text disables following without moving recording controls.

The recording card keeps fixed timer, stop, meters, and settings disclosure. Its collapsed height follows its content; only expanded settings may scroll within the existing height budget. Saved transcripts have a fixed action/history header: one eligible provider gets a named action, multiple providers get a menu, and no provider gets setup. Pending requests retain their provider and recovery actions. Live checkpoints remain recoverable through history without a duplicate text accordion.

Finalized live text becomes the main transcript through the coordinated backend change. Existing checkpoints with no selected transcript remain visible, and editing can adopt them explicitly without a separate adoption screen. Live-state observation stays inside the Transcript component so partial results do not update the recording card or library.

## Validation

Implemented the shared transcript row, isolated live tab, saved transcript/history panel, direct provider actions, and compact recording card. The legacy checkpoint fallback respects the adoption marker, so intentionally cleared text does not reappear.

The integrated baseline passed formatting, lint, and 260 tests. Isolated Preview screenshots confirmed live rows appear in Transcript, the recording settings expand independently, and turning live text off retains finalized text. Stop & Save made the finalized phrase editable in the main transcript, with a clickable timestamp and no speaker label. The zero-provider setup action and history menu were visible. Final integration checks include the subsequent legacy-adoption regression.

No installed-app interaction, hardware capture, model download, or provider upload occurred. This pass checked the current dark appearance and normal window; narrow-window, light appearance, and provider-menu variants remain to be checked in the follow-up highlighting pass.

## Technical debt

None. The checkpoint fallback is a compatibility path for existing saved recordings; startup migration adopts safe empty transcripts, and explicit history restoration preserves previous text. Provisional-word highlighting is a separately requested follow-up.
