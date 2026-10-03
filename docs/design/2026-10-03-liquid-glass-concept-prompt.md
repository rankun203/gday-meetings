---
title: Liquid Glass concept generation prompt
date: 2026-10-03
status: proposed
scope: swift-app-design
---

# Concept generation prompt

Tool: built-in image generation. The final revision places search in the sidebar. All meeting content is synthetic. See the [proposal](../worklogs/2026-10-03-liquid-glass-refresh.md) for authoritative behavior and differences between the illustration and intended implementation.

```text
Use case: ui-mockup
Asset type: high fidelity desktop macOS application design proposal, one straight-on screenshot, wide landscape 1800x1200 composition.
Primary request: Modernize Gday Meetings using restrained native Liquid Glass chrome, preserve efficient three-column meeting layout and wide bottom waveform. This is a realistic, buildable productivity application, not a marketing page.
All content must be synthetic. Do not use personal content from reference screenshots.
Dark mode charcoal opaque reading surfaces, crisp SF-style typography, blue accent, subtle neutral glass with delicate edges, no neon, no dramatic gradients, no thick outlines.
Layout: full window with macOS traffic lights and unified compact top toolbar: small headphone logo and Gday Meetings at left, red record-dot New Recording control, import icon, overflow at right. NO search field in the top toolbar. Below: left inset rounded translucent sidebar with a clearly visible Search Meetings input at its TOP, above all navigation items, like the macOS App Store. Sidebar is wide enough for this search field. Below the search field, Meetings selected (soft neutral pill, blue icon/text), People, Tags, Tasks, Agents. Center meeting list roughly 27 percent width, quiet opaque surface, 8 dense rows with title, date/duration, one summary title line (no markdown #). Titles: Planning Review, Design Review, Weekly Check-in, Release Planning, Research Review, Team Update, Project Kickoff, Sprint Review. Selected Planning Review subtle blue tint.
Right detail roughly 58 percent: small play icon with title Planning Review; metadata Today at 10:00 AM · 32:10; tag Planning; language English. Compact rounded segmented navigation Transcript (selected), Notes, Summary, Data Privacy, with NO keyboard focus border. Below a quiet action row Re-transcribe and Transcript History; small source label Recorded Transcript. Transcript is comfortable plain text rows, timestamp and speaker chip at left. Generic speakers Alex and Sam. Show rows 08:12 Alex 'Let’s review the next milestone.'; 08:18 Sam 'The first draft is ready for feedback.'; 08:24 Alex 'We can review the open questions today.'; 08:26 Sam 'I’ll collect the comments after this meeting.'; 08:34 Alex 'Then we can confirm the next steps.'; 08:42 Sam 'That works for me.' Highlight BOTH 08:24 and 08:26 with restrained blue-tinted row backgrounds to show overlapping playback. Speakers disclosure at bottom.
Bottom: ONE wide floating rounded glass player, inset just 12 pixels from window sides, spans ALL THREE COLUMNS, roomy 105 pixel height. Has left small waveform tile and Planning Review / Playing, skip-back-15, pause, skip-forward-15, LONG horizontal blue waveform occupying at least half entire bar width, 08:28 and remaining -23:42 below waveform, 1× and All Tracks controls on right with expansion chevron. Reserve clear space behind bar so no transcript text is hidden. Do not shrink waveform into a tiny music scrubber. Soft border/shadow, content remains legible.
No external captions, annotations, decorative cards, album art, photographs, wallpapers, or new features. Match genuine desktop UI density and accurate readable labels.
Critical requirement: Search Meetings input lives ONLY inside the LEFT SIDEBAR above Meetings, never in top toolbar or main content. Keep top toolbar empty at right except small action buttons. Capsule-shaped content tabs, small title play button, opaque flat reading backgrounds. Preserve existing waveform icon for Meetings, person.2 for People, tag for Tags, list for Tasks, chat bubbles for Agents. No per-row overflow menus or meeting count.
The sidebar search field is idle with placeholder Search Meetings. Submitting it would open a dedicated Search Results destination, but this single image depicts the normal Meetings screen, not results.
```
