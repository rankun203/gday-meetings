---
title: Writing guide
date: 2026-09-26
status: active
scope: all-apps-and-documents
---

# Writing guide

## Apple guidance

This is a paraphrased summary, not a copy of Apple's text. Source: [Apple Human Interface Guidelines — Writing](https://developer.apple.com/design/human-interface-guidelines/writing), reviewed September 26, 2026.

- Establish a consistent voice and vocabulary. Adjust tone to the situation.
- Use familiar, precise words. Remove words that add nothing. Read text aloud to check clarity.
- Write inclusively, with accessibility and translation in mind.
- Put the screen's main information first. Divide complex explanations into manageable steps.
- Use active language and descriptive actions for buttons and links.
- Repeat established terms and patterns. Keep capitalization and navigation labels consistent.
- Omit unnecessary possessives and avoid an ambiguous “we.”
- Match instructions to the device and its input methods.
- Give empty screens a useful next action. Keep essential guidance accessible elsewhere.
- Place errors near their cause. Explain recovery without blame or playful interjections.
- Match a message's presentation to its urgency and context.
- Name settings plainly. Explain their enabled behavior when needed, and link directly to them.
- Label fields, give useful format examples, and explain corrections beside the input.

## Repository conventions

These rules apply the guidance to Gday Meetings. They are project decisions, not quotations from Apple.

### Describe the task

Give people the information needed for the current action. Avoid slogans in setup, empty states, and errors.

| Avoid | Use in context |
| --- | --- |
| Ready to record. No account needed. | Select Record Meeting to start a recording. |
| Unable to Complete Action | Couldn't transcribe this recording. |
| Check the endpoint, model, and API key. | Enter an access token for Office Server. |
| Everything stays on your Mac. | Recordings and notes are saved on this Mac. |

Explain account requirements in service setup or product documentation when they matter. Do not repeat them beside an unrelated action. State that recording works offline in the feature description.

### Keep names consistent

Use **provider** for a configured connection or account and **capability** for a feature it supports. Use **Speaker Diarization** for distinguishing voices and **Speaker Association** for matching them with the **People Library**; define diarization when discussing its protocol. Use **General** for behavior settings and **Service Providers** for provider configuration and repairs. Use **Gday Meetings website** in the UI; explain CMS only in technical documents.

Group recording behavior under **Record**, **Recording**, and **After Recording**. Use verb phrases for switches: **Automatically Transcribe**, **Automatically Diarize**, **Automatically Associate People**, **Automatically Summarize**, and **Automatically Extract To-Dos**. Use **Transcribe** and **Label Speakers** for the current recording's processing switches. Use stage modifiers on capability names when needed, such as **Live Transcription** and **Speaker Diarization**. Do not use “Speaker Recognition” to combine labeling and association.

Use title case for named controls and settings, and sentence case for explanatory text and document headings. Follow platform requirements for specific controls. Use an ellipsis when an action needs more input before it completes. Use the same label wherever the same action appears.

### Separate interface copy from design instructions

Mark exact interface text with quotes, bold text, or a labeled example. Put implementation behavior in a separate sentence or table column. Do not present placeholder prices, retention periods, or security claims as released behavior.

Technical documents may use precise engineering terms. Define unfamiliar terms on first use and explain their effect on the person using the app. Preserve conditions and limitations when shortening text.

### Review before finishing

- Does each message identify the relevant task, object, or problem?
- Does each action label describe what happens next?
- Are names, capitalization, and labels consistent with the surrounding flow?
- Are example messages distinct from implementation requirements?
- Are claims supported, with proposals and unresolved details clearly identified?
- Can any sentence be shorter without losing necessary meaning?

When reviewing an entire document, read every section, table, diagram, and copy example. Automated checks for links or formatting do not replace this review.
