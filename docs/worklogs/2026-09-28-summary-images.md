---
title: Images in meeting summaries
date: 2026-09-28
status: complete
scope: swift-summary-images
---

# Images in meeting summaries

## Problem

Summary requests included Notes text and image paths but no image bytes. Provider model lists retained only IDs and names, so the app could not establish image input support. Reading-mode image links opened an external application.

## Implemented solution

- Preserve model input modalities and add a scoped Image Input override in provider settings. Automatic uses explicit metadata; unknown support stops image-containing summaries before content submission with an actionable setting choice.
- Prepare original Notes images off the main actor, deduplicate paths, constrain source dimensions and file size, resize to 2,400-pixel JPEG, and enforce 20 images/20 MB compressed bytes. Send text and image parts in both transport paths, with relative source paths and citation instructions.
- Open safe meeting-local source-image links in a resizable Quick Look window. Retain saved summary image references during cleanup and include them in exports, imports, and archive manifests.
- Explain image transfer and limits in settings, privacy details, and the summarization protocol. Preserve text-only request behavior and custom prompts.

## Reasoning

OpenAI-compatible model lists do not have a universal capability field. Explicit input modalities and a model/endpoint-scoped override avoid model-name guesses. Unknown support requires a deliberate choice instead of presenting a summary as though it inspected screenshots. Bounded JPEG preparation balances screenshot legibility with request size; original images remain available in the popup.

The existing provider panel screenshot showed grouped Connection rows with Model followed by status. The design adds Image Input and concise supporting text immediately below Model. Existing summary layout stays unchanged; descriptive links open a native image window. Only synthetic Preview content was used.

## Technical debt

Provider metadata has no universal schema or expiry contract. Automatic currently recognizes OpenRouter-style input modalities and otherwise requires an override. Cached metadata refreshes in Settings; a provider may change support later, producing a request error. Add adapters for other documented capability schemas when supported providers expose them.

Image conversion is lossy and bounded, so very small screenshot text may be unreadable. Originals remain unchanged; future adaptive tiling or provider-specific image limits can improve detail without silently enlarging requests.

## Validation

No real meeting images were uploaded. Initial full suite compiled and ran 432 tests; source-change validation intentionally changed an existing background-job expectation, now updated by the summary-isolation task. Existing timing-sensitive transcript-hover and audio-drop monitor checks also failed in that parallel run. The consolidated 48-test run passed all summary lifecycle, route, background, and retention suites; one new timestamp-format assertion was corrected to match NotesDocument. The subsequent focused run passed all 14 image and export tests, including actual streaming/nonstreaming request bodies through loopback, scoped capabilities, image loading, retention, export/import, and archive payloads. Swift formatting lint and diff whitespace checks passed. Both timing-sensitive checks passed in isolated retries. Production Preview built successfully. Existing Command Line Tools linker warnings remain for missing Developer library/framework search paths; no new source deprecations were reported. These toolchain search paths predate this change and require a compatible full SDK/toolchain installation to remove.

Captured and inspected before/after provider Settings and Summary in isolated Preview. Image Input appears below Model with readable unknown-support explanation; selecting Text Only updates its explanation. The synthetic summary’s descriptive image link opens the original in a resizable native Quick Look dialog. Paused player retains its label and Play control without a device notice. Dark/System appearance was checked. Light appearance, narrow settings windows, keyboard-only popup activation, and real provider vision quality were not independently verified in this task. No real library or installed app was restarted. The final size-limit copy clarifies that 20 MB is before encoding; that wording-only refinement follows the Preview build.
