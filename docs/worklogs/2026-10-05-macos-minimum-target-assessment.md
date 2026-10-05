---
title: macOS minimum target assessment
date: 2026-10-05
status: assessment-complete-decision-pending-implementation
scope: swift-macos-platform-support
---

## Problem

Decide whether to raise the Swift app's minimum macOS version from 14.2 by distinguishing existing feature differences, native appearance, future API opportunities, and maintenance costs.

This assessment reviewed the Swift source, dependency requirements, and Apple's documentation. It is a code and API assessment, not evidence that every feature has been tested on every OS. Apple's version sequence here is 14 → 15 → 26 → 27. The source was under active development during the review.

## Preferred direction and handoff

The maintainer prefers raising the minimum to macOS 26. Users staying on macOS 14.2 can use [v0.3.0](https://github.com/rankun203/meeting-notes/releases/tag/v0.3.0), identified by the maintainer as supporting 14.2. That release's compatibility was not independently validated in this assessment.

This worklog records the assessment only. No deployment target, build configuration, source behavior, or release policy was changed by this documentation task. Another agent will continue the decision and implementation.

## Existing features

macOS 26 is the meaningful feature boundary for this app. macOS 15 mainly removes small compatibility fallbacks. macOS 27 offers useful future APIs, but current features do not require it.

| App feature | macOS 14.2 | macOS 15 | macOS 26 | macOS 27 |
| --- | --- | --- | --- | --- |
| Microphone and system-audio recording | Supported | Same architecture | Same architecture | Same architecture |
| Separate audio tracks, voice processing, device switching | Implemented | Implemented | Implemented | Implemented |
| Opus/AAC/WAV recording and playback | Supported | Supported | Supported | Supported |
| Apple live transcription — This Mac | Unavailable | Unavailable | Available on supported hardware and languages | Available, with additional APIs we could adopt |
| Provider-based transcription, summaries, to-dos, and chat | Supported | Supported | Supported | Supported |
| Local speaker labeling and voice matching | Existing Core ML path; model and hardware constraints apply | Same | Same, potentially different runtime performance | Same; no automatic model upgrade |
| Native navigation, toolbars, menus, and controls | Older native appearance | Sequoia appearance | Liquid Glass appearance | Refined Liquid Glass appearance |
| Custom glass transport/navigation surfaces | Material fallback | Material fallback | Native glass | Native glass |
| Meetings, People, Tags, and Tasks infinite scrolling | Can support the same behavior | Same | Same | Same |
| Search, task history, recovery, and library storage | Same app architecture | Same | Same | Same |
| Markdown, transcript editing, images, and timestamps | Existing native editor | Same functionality | Same functionality | Same functionality |
| Export format selection | Custom accessory picker | Native save-panel format picker | Native picker | Native picker |
| Option-key recording menu | Option-click fallback | Menu item changes while holding Option | Same | Same |
| Pointer and image-resize cursors | Manual/custom fallback | Newer native APIs | Same | Same |
| Transcript color blending | Older AppKit implementation | Newer SwiftUI color API | Same | Same |

The recording floor of 14.2 is deliberate: system-audio capture uses Core Audio process taps, whose SDK declaration starts at 14.2. Microphone capture uses AVAudioEngine rather than ScreenCaptureKit. See the [audio architecture](../../apps/client-macos-swift/docs/AUDIO_DESIGN.md).

The largest functional difference is live transcription. The implementation deliberately uses SpeechAnalyzer and SpeechTranscriber, with no legacy recognizer fallback. Even a minimum of 26 would not guarantee transcription on every device or language; Apple requires runtime availability checks. See [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber).

Appearance depends on the running OS and linked SDK, not simply the minimum target. Newer systems can deliver their native appearance while the app still supports 14.2. macOS 27 further changes sidebar edges, selection emphasis, and toolbar glass automatically. See [Liquid Glass adoption](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) and [AppKit changes in 27](https://developer.apple.com/videos/play/wwdc2026/289/).

## Opportunities not yet adopted

These require implementation work. Raising the minimum alone would not add them. Their potential value to this app is an engineering assessment, not a measured improvement.

| Opportunity | Version boundary | Potential value | Reason to raise the minimum? |
| --- | --- | --- | --- |
| New SwiftUI scroll geometry, visibility, and position APIs | 15 | Could simplify some scrolling logic. Native tables already provide reuse and precise anchoring. | Weak |
| ScreenCaptureKit microphone and direct recording output | 15 | Useful if screen/video recording is added. Little benefit to the current audio-only architecture. | Weak for current scope |
| SwiftUI rich-text TextEditor | 26 | Could simplify a future editor, but must preserve Markdown, timed gutters, images, undo, and selection. | Moderate only with an editor migration |
| Apple Foundation Models | 26 | Potential on-device summaries, extraction, and meeting questions. Requires eligible hardware and model availability. | Strong if it becomes a core product feature |
| New Speech input/conversion helpers | 27 | Could replace parts of custom audio-to-analyzer conversion and input handling. | Moderate maintenance benefit |
| More expressive toolbar overflow and prioritization | 27 | Better control over which actions remain visible in narrow windows. | Weak by itself |
| New document APIs | 27 | Potentially useful for a future document-based meeting/package workflow. The library currently manages files directly. | Weak for current architecture |
| Expanded Foundation Models integration | 27 | New model-provider and multimodal capabilities could support a future AI architecture. | Strong only with a concrete adoption plan |

Sources: [SwiftUI updates](https://developer.apple.com/documentation/updates/swiftui), [ScreenCaptureKit updates](https://developer.apple.com/documentation/updates/screencapturekit), [rich-text editing](https://developer.apple.com/videos/play/wwdc2025/280/), [Foundation Models availability](https://developer.apple.com/documentation/FoundationModels/generating-content-and-performing-tasks-with-foundation-models), [Speech updates](https://developer.apple.com/documentation/updates/speech), and [macOS 27 capabilities](https://developer.apple.com/macos/whats-new/).

## Reasoning and target options

- A newer minimum will not fix Tasks performance or provide infinite scrolling. Those depend on indexing, loading, and rendering implementation.
- Newer development tools do not always require a newer minimum. Apple back-deploys the new State initialization behavior to macOS 14. See [SwiftUI WWDC26](https://developer.apple.com/videos/play/wwdc2026/269/).
- OS support and CPU support are separate decisions. Builds target the build machine's architecture. At review time, CI covered Apple silicon on 15, 26, and 27, not Intel or macOS 14. See [repository validation coverage](../../apps/client-macos-swift/README.md#release-build-checks).
- A minimum of 27 excludes Intel Macs entirely. Apple lists macOS 27 compatibility as Apple-silicon Macs. See [Apple's compatibility list](https://support.apple.com/en-us/127255).

| Minimum | When to choose it |
| --- | --- |
| 14.2 | Broad compatibility matters, and live transcription can remain optional. Add real 14.2 runtime testing. |
| 15 | Seek a modest maintenance reduction and a minimum aligned with the oldest current CI runner. Little product capability changes. |
| 26 | Center the product on modern native design and Apple live transcription, accepting loss of older OS users. The strongest upgrade candidate. |
| 27 | Deliberately commit to Apple silicon and specific 27-only features. Current requirements do not justify it yet. |

The assessment recommended retaining the existing minimum for redesign and scrolling alone, or choosing 26 for a broader product decision prioritizing Apple's local speech and AI capabilities. The maintainer subsequently expressed a preference for 26, with v0.3.0 as the older-OS fallback. Hardware and language availability checks remain necessary either way.

## Technical debt

None introduced by this documentation task. Existing compatibility branches and the missing macOS 14/Intel runtime coverage remain as assessed above; changing support policy or removing branches requires implementation and validation in the follow-up task.
