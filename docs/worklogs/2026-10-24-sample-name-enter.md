---
title: Sample-name dialog interactions
date: 2026-10-24
status: implemented
---

## Problem

The sample-name editor could choose typed-name creation while a matching person was highlighted. Submission and default-button routing used an additional explicit-selection flag rather than the visible selection alone.

## User Intention

In both Edit Sample Name and Name This Person, pressing Enter or Use Name should apply the highlighted person. Double-clicking a row should apply that person. The list should blend with the dialog rather than showing a white background. Preserve the existing Test11 app and its trial library while implementing and validating this correction. The user subsequently requested Test12 based on the prior Test11 session.

## Implemented solution

The editor gives the selected person priority in its shared submit action. Text-field submission, list Return, and the default Use Name button use that action. A separate Create button remains available for a new typed name; creation becomes the default only when no person is selected. Query changes and arrow navigation retain their existing selection behavior. Rows expose their full width as a hit target. Single-click explicitly updates the shared selection; a simultaneous double-click applies that row. Native keyboard navigation remains available. The scroll content background is hidden so the dialog material shows through. Save guards, failure messages, retry, cancellation, and dismissal are unchanged.

## Reasoning

The supplied screenshot establishes the existing layout and highlighted-row state. Keep that layout, with Use Name as the default whenever a row is selected, full-row double-click targets, and the dialog background visible through the list. Removing the explicit-selection flag makes the visible selection the authority for submission, including automatically highlighted search results.

## Technical debt

None.

## Notes

Source baseline: 027db65. Final source hash for PersonMatchReviewView.swift begins 5019a006. Validation uses a separate checkout under ignored tmp/sample-name-enter; Test11 and its trial library remain unchanged. Changes are uncommitted.

- Final release build passed (macOS 26 minimum, SDK 27), as did formatting, diff review, packaging, and signature verification. The final synthetic preview identifies revision 027db65-sample-name-5019a006 and uses a distinct bundle identity. Packaged source matches the working tree.
- All 12 VoiceGroupNamingTests passed on the initial Enter change, including failed creation, concurrent edits, and guarded Undo. Later changes affect row gestures and background presentation; persistence code is unchanged.
- Native checks became available after the session restarted. Enter applied the highlighted person in both dialogs. A partial-name search used the existing match even with Create available. Use Name applied the selected person in both dialogs. Undo restored the prior decision; Escape cancelled without naming the voice. An unmatched name exposed Create.
- Native testing exposed a missing single-click selection update. Explicit row selection fixed it. On the final build, single-click changed the highlighted row and Use Name applied it; double-click applied the clicked person in Name This Person. The naming sheet background blends in Light and Dark; the sample popover's visible list background blends with its material.
- Popover pointer testing remains limited: coordinate clicks did not reach any popover control, including Cancel, while accessibility button actions and keyboard input succeeded. Consequently, single/double-click in Edit Sample Name is implemented through the same verified shared row handling but remains unverified end to end. The tool's popover screenshot also clips its top. IME composition and held-key repeat were not exercised.
- Existing Command Line Tools linker warnings report missing Developer/usr/lib and Developer/Library/Frameworks search paths. No new deprecation warnings appeared. Toolchain path maintenance remains outside this dialog change.

Focused remaining manual check: in Edit Sample Name, click a different person and press Enter, then reopen and double-click another person. Verify the highlighted person is applied each time. Use the isolated preview; the running Test11 build does not contain these changes.

## Test12 delivery

Checked the prior Test11 packaging scripts and manifest against base commit 027db65. Packaged the validated final release binary as Test12 with its own bundle identity and explicit data directory. Captured the latest Test11 durable state for 20 completed meetings and 107 voice examples using independent clones/copies under a shared voice-library lock. Source stat and full hashes stayed unchanged during capture; no pending transaction or finalization markers were present. Kept meeting-scoped decisions and representations, omitted tasks/jobs/Undo/indexes, disabled remote providers and automatic processing, and retained an independent baseline. Signature verification passed. Native launch showed 20 meetings; runtime open-file checks confirmed the Test12 library and no open Test11 library files. Test11 and the main library were preserved. Source changes remain uncommitted.
