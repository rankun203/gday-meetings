---
title: Recording bar hover
date: 2026-10-01
status: validated
scope: swift-app-ui
---

# Recording bar hover

## Problem

The supplied screenshot shows hover feedback confined to the recording's
meeting title. The playback bar uses one navigation button for its icon and
both text lines, making the recording bar's smaller target inconsistent.

## Implemented solution

`RecordingStripTitle.swift` makes the recording icon, status, and meeting title
one button using the player's existing `ActionButtonStyle` and rectangular
hit shape. Ordinary clicks show the recording; Command-click reveals its
folder. VoiceOver exposes **Show Recording** and **Reveal in Finder**.
`LibraryView.swift` replaces only the corresponding label block.

The existing spacing and typography remain. Duration, **Show Recording**, and
**Stop & Save** remain separate controls. Preparing without a meeting identity
still presents a passive status label. Saving retains the progress indicator.

## Reasoning

Use the same button style as playback so hover and pressed feedback cover the
complete label without changing geometry. The implementation adds no timers,
capture actions, cursor overrides, or new interaction styling.

## Technical debt

None.

## Validation

Before-state evidence: user-supplied recording-bar screenshot and inspection of
the playback title button. Release build and after-state screenshots are pending
central validation in the isolated validation app. No real recording was
stopped, and no app was launched for this change.

Targeted `swift-format` formatting and strict lint passed for the new component
and `LibraryView.swift`; `git diff --check` passed. The existing log-follow
changes in `LibraryView.swift` were preserved. The documentation index is left
for central integration as requested.

Check the synthetic recording while viewing Tasks or another meeting:

- Hover the icon, status, title, and gaps between them. All should show the
  same complete-label highlight without moving text or duration.
- Click each part to show the recording. Confirm duration and **Stop & Save**
  are outside the navigation target.
- Command-click to reveal only the synthetic meeting folder.
- Use keyboard focus and activation; inspect the **Show Recording** label and
  **Reveal in Finder** accessibility action.
- Compare light and dark appearances, narrow and wide windows, and the playback
  title button. Check preparing and saving states if preview exposes them.

## Combined validation

Combined validation passed: 517 tests in 96 suites (66.864 seconds), strict Swift formatting/lint, and isolated `make build-macos` (54.65 seconds), including signing. The build retained the documented missing Command Line Tools search-path linker warnings. No new API deprecation warning appeared. The real recording and running app bundle were preserved.

The separate validation app exposed one **Show Recording** button for the icon/status/title, with **Reveal in Finder** as an accessibility action. Clicking the status text and activating the complete button both navigated from Tasks to the active synthetic recording. Screenshots in System (light) and Dark showed the intended unchanged geometry beside duration and stop controls. Continuous pointer-hover rendering, Command-click, keyboard activation of this specific button, narrow windows, and preparing/saving states were not verified through the automation tool. Shared playback button styling was confirmed in source.

The user later reported a frozen-looking preview and high WindowServer/Computer Use CPU. A two-second stack sample of the validation process showed event-loop waiting and rendering, not a sustained deadlock. The synthetic validation process was terminated without touching the real recorder. Resetting the automation session did not stop the helper's rendering load; terminating that helper reduced its CPU to zero and lowered WindowServer load in the next observation. Further GUI checks were stopped. This establishes a validation-tool issue, not a complete explanation of the machine's remaining rendering load.
