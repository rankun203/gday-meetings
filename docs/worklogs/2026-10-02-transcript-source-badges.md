---
title: Transcript source badges
date: 2026-10-02
status: complete
scope: macos-transcript
---

## Problem

When Speaker Labeling was off, audio-source placeholders looked like detected voices and offered person assignment. A source can contain several people, so assigning that source implies an identity the app has not established.

## Implemented solution

Live source badges show `mic` and `sys`. The native transcript table retains its timestamp, badge, and text columns and source colors, but source badges use a plain filled background without the unassigned-speaker dotted outline. Double-click, context menus, and accessibility actions do not open person assignment for those badges. Transcript text remains editable.

Saved speaker entries carry an optional audio-source marker. Adoption preserves that marker; existing adopted transcripts recover it only from matching identities in their original live checkpoint. Assignment is also guarded in the live controller and meeting store. Detected speakers remain assignable even without embeddings. Existing explicit source assignments keep their names and can be removed in the saved Speakers section; unassigned sources are omitted there.

Preview inspection also exposed an initial-display issue: the empty view did not observe changes to its reference-type row cache. The cache now publishes its revision through `ObservableObject`, and the view owns it with `StateObject`, removing the separate generation state. The synthetic fixture seeds a prior manual assignment directly rather than invoking the now-disallowed source assignment action.

## Reasoning

The parent agent captured and inspected the running app’s original dark transcript state without changing the recording. It showed source placeholders using the same dotted capsules as unassigned detected speakers. The intended design keeps the compact layout and separates source information from voice identity through concise text and available actions.

Real local speakers can also be named `mic_01` or `sys_01`, and speaker detection does not require an embedding. Neither the label nor missing embeddings can safely identify a source placeholder. Explicit provenance and checkpoint identity matching avoid guessing or removing valid speaker actions.

## Technical debt

Older standalone transcripts without their original checkpoint cannot distinguish a source placeholder from a real detected voice. Their existing behavior is retained to avoid guessing. Recovery requires the original checkpoint or explicit future user-provided provenance; the new source marker prevents this ambiguity in newly saved transcripts. No temporary duplication or schema rewrite was introduced.

## Validation

The final complete sequential suite passed 706 tests in 120 suites. Regressions cover source/detected identity separation without embeddings, cell reuse clearing assignment menus and accessibility actions, persisted provenance, legacy checkpoint recovery, assignment rejection, preserved manual attribution, and the synthetic fixture. Formatting, lint, and diff checks pass. Final `make build-macos` passed in the isolated checkout, including release compilation, packaging, and signature verification.

The parent agent inspected synthetic Preview screenshots in light and dark appearances at 900-point and wider window sizes. Source badges show `mic` and `sys` with plain filled backgrounds and unchanged columns. Double-clicking a source opens no picker; its context menu contains only **Copy Text** and **Edit Transcript**. Editing opens the text editor, and Escape cancels. Synthetic **Stop & Save** preserves the source labels, excludes person assignment from saved-row menus, and omits an empty Speakers section.

The final-source preview displayed rows immediately on opening the recording, without toggling a control. A prior manually assigned source retained its name through **Stop & Save**. Its Speakers entry offered only **Remove Assignment**; choosing it restored `sys` and hid the now-empty section. These final interaction checks used the source-matched debug executable while the release build ran separately.

The production recording remains untouched. Preview checks use synthetic content and do not validate capture or inference. Linker warnings report missing Command Line Tools search directories (`Developer/usr/lib` and `Developer/Library/Frameworks`); these were present in the baseline build. No deprecation warnings were reported. The missing search paths originate in the selected toolchain, not changed app APIs; verify them with a complete Xcode toolchain when available.
