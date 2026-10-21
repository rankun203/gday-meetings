---
title: Default recording language
date: 2026-10-21
updated: 2026-10-22
status: validated
scope: swift-app-recording
---

## Problem

Recording setup reused a fixed language preference without remembering the
language used in the preceding recording. General settings placed that preference
in a separate Transcription Language section.

## User Intention

Add Default Language after the two audio-source switches in General → Record.
Offer the language list with Use Last Recording as the final option. Remove the
separate Transcription Language section. Apply the choice to New Recording and
the menu-bar start action while keeping each recording's language editable.
The user requested a Claude Code Opus 5.5 review and a commit.

## Implemented solution

- Added a remembered recording language and a choice between a fixed language and
  Use Last Recording. New and older settings default to Use Last Recording; until
  a recording has been remembered, the existing language preference is the fallback.
- Both recording entry points use the resolved language. New notes, media imports,
  and provider health checks use the same resolved default.
- Remember the language after capture and metadata save succeed, and after saved
  language changes during an active recording. A session identifier lets an edit
  finish saving after Stop without overwriting a newer recording. Editing an older
  meeting leaves the remembered language unchanged. A fixed default stays fixed.
- Moved the shared language picker into Record, added Use Last Recording last,
  and removed the Transcription Language section. Its information popover explains
  the additional choice.

## Reasoning

The fixed preference and recording history are separate values so session overrides
cannot replace an explicitly selected default. The existing settings persistence
path saves both values across launches. Saving after successful recording startup
avoids remembering cancelled or failed attempts.

Before editing UI, inspected and captured the running General screen. The design
places Default Language below System Audio and above Audio Format, retaining the
native picker, shared card style, and existing two-column layout. The separate
right-column language card is removed.

## Technical debt

None.

## Notes

- Regression coverage includes legacy decoding, fixed and remembered modes,
  persistence, failed starts, active-recording edits, and saved-meeting edits.
- Claude Code Opus 5.5 found no blocking issues in the final review. Accepted its
  active-recording edit, error-context, persistence-test, resolved-language-test,
  and save-ordering suggestions. Added a queued-save regression for Stop racing
  with a language edit. The successful capture-start call has source inspection;
  the helper's persistence has an automated test. No real-capture success test is
  claimed. Optional changes to provider warnings and dynamic menu labels were
  left outside this change to retain the requested wording and existing health UI.
- Formatting and lint passed. All 20 focused tests passed across RecordingDefaults,
  ProviderHealth, and MeetingLanguage. The final isolated `make build-macos`
  release rebuild passed, including platform checks and signing.
- Isolated release and Preview packaging passed using macOS 26.6.2 and SDK 27.0,
  targeting macOS 26. Toolchain linker warnings mention missing Command Line Tools
  framework/library search paths; no deprecation warning was observed. These
  paths are supplied by the toolchain, and compilation, linking, and signing pass.
- Inspected before/after screenshots through computer use. Preview was built from
  the scoped working diff over revision 486fb97 at
  `/tmp/gday-recording-language-validation`, with its standard synthetic fixtures
  and a unique preview bundle identifier. Verified light/dark appearance, placement
  after System Audio, removal of the separate card, last menu option, keyboard
  End/Return selection, French prefilling New Recording, editing to German, and
  cancellation preserving the French default. Layout remained stable.
- Real capture and the menu-bar action's audio startup were not exercised; their
  shared default resolution has source review. Preview disables capture.
- The first build encountered missing types in concurrent, unrelated review-screen
  work. Validation moved to an isolated checkout containing only this task's diff.
