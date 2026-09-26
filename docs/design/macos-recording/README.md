---
title: Recording and listening design
date: 2026-09-26
status: active
scope: swift-app-design
---

# Recording and listening design

The [current design brief](imagegen-prompt.md) describes recording and listening states. The sidebar contains Meetings, People, and Tags; connections belong in Settings → Service Providers. The September 24 generated concept is retained as historical worklog evidence and is not a current navigation reference. Product views use native controls rather than a generated image.

Actual SwiftUI component renders:

- [Recording setup](implemented-setup.png)
- [Expanded setup scrolled to its options at 400-point height](implemented-setup-expanded-compact.png)
- [Recording with notes](implemented-recording.png)
- [Compact recording workspace in dark appearance](implemented-recording-compact-dark.png)
- [Persistent player](implemented-player.png)

These are offscreen renders with synthetic meeting data/source levels and a paused one-second silent audio fixture, not screenshots of a live meeting. Standard controls render with inactive-window gray styling; the active recording button uses the native red tint. The harness did not display windows, request permissions, play or record audio, use the real library, access credentials, or make network requests. It validated component layout, including a 440×550-point detail and 900-point player. Interactive keyboard/VoiceOver and full-window behavior remain to be verified when native UI automation is available.

Setup regression checks also cover expanded options and long errors at 400/480/600-point heights in light/dark appearance, plus automatic scrolling to a new error and pinned startup progress. The form scrolls independently of its header and action buttons.
