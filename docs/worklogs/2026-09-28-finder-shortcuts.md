---
title: Reveal meetings and audio in Finder
date: 2026-09-28
status: validating
scope: swift-app
---

# Problem

The player and meeting list needed direct access to their authoritative files without navigating the data folder manually.

# Design and implementation

The parent agent captured the expanded player before editing: the title was a meeting-navigation button and Microphone/System Audio were plain labels. Keep that layout and ordinary interactions. Command-clicking the player title reveals the meeting folder; Command-clicking an expanded track label reveals the original audio file. Help describes the modifier, and both expose a named Reveal in Finder accessibility action. Track labels also offer the action in a context menu.

The meeting-list context menu now includes **Reveal in Finder** between Play and Export Meeting. It resolves the clicked row’s folder independently of selection. The player uses its own meeting ID and original source-file list, so browsing a different meeting or using a temporary decoder file cannot reveal the wrong item. Finder selects the requested item using `activateFileViewerSelecting`.

# Reasoning

Use the existing title button rather than intercepting all player clicks. Track-label gestures stay separate from mute controls and waveforms. The added playback accessor is read-only and checks track bounds.

# Validation

The release Preview build passed. The meeting context menu showed Reveal in Finder and selected the copied meeting folder in Finder. The expanded System Audio track’s named accessibility action selected its original `system_audio.opus`, not a decoder file. Ordinary player-title click returned to the playing meeting. Command-modifier branches were code-reviewed; automation exercised their shared reveal actions rather than a physical Command-click. No actual recording or user file was modified by these checks.

# Technical debt

None.
