---
title: Recording and persistent player design brief
date: 2026-09-26
status: active
scope: swift-app-design
---

# Recording and persistent player design brief

Revised from the September 24 concept brief to match the current sidebar. The earlier generated image is historical and no longer defines app navigation. Implemented controls use native SwiftUI and SF Symbols. Illustrative names, counts, tags, and the rich-text toolbar are not feature commitments.

## Prompt

Use case: ui-mockup
Asset type: high-fidelity design concept board for a native macOS SwiftUI app, Gday Meetings.
Primary request: Reimagine a meeting recorder with Apple Music's elegant thoughtful hierarchy, and a persistent player that lets people browse meetings and edit notes while listening. Show two polished large macOS app windows stacked on one clean presentation board: upper window "Recording"; lower window "Listening while browsing". No laptop/device mockup. Crisp readable interface with native SF-like typography, gentle system materials, subtle separators, lots of purposeful whitespace, adaptive neutral light appearance, restrained system-blue accents and recording-red only for live recording.
Upper window: native traffic lights and toolbar, slim left sidebar with Meetings, People, Tags; middle list of meetings with today's Design review selected; right workspace with editable heading "Design review", understated date and people/tag metadata. A beautiful recording card with small red dot and "Recording", large monospaced "12:48", two horizontal genuine-looking source level meters labelled "Microphone" and "System audio", quiet line "Voice processing on", ONE prominent red "Stop & Save" button. No pause recording button. Below is a simple content tab strip Notes, Transcript, Summary, To-Dos, Chat; Notes selected and useful readable short meeting notes. Recording is obvious without consuming the whole window.
Lower window: same app structure, user browsing a different meeting "Planning notes" while persistent compact playback bar at bottom spans main content: modest blue waveform artwork tile, now playing title "Design review", real play/pause center control with skip backward15 and forward15 controls, thin progress scrubber with "08:24" and "32:16", secondary "1x" playback speed and "All Tracks" source menu. No fake functionality like shuffle, heart, random album covers or unrelated music actions. Player does not obscure notes. Primary toolbar button "New Recording" has red record glyph but sober native style; import and more actions secondary.
Constraints: production-plausible native macOS design following Apple HIG. Avoid dashboards, dense scattered button rows, oversized empty-state icons, decorative waveform art pretending to be real data, glass blobs, neon, web-app cards everywhere. This is a concept for native controls implemented later in SwiftUI, not a bitmap placed in the actual UI. Make the visual organization feel calm and intentionally designed.
