---
title: Search result passage range preview
date: 2026-10-07
status: complete
scope: html-design-preview
---

## Problem

The search layout preview placed passage timestamps in the metadata column, away from their excerpts, and did not show matching duration.

## Implemented solution

Updated `output/search-layout/search-results.html`, the 750px synthetic design preview, with a static range above each transcript excerpt. Start and end times label its endpoints; duration appears between them. Title matches omit the range. Preview dialogs also show the passage's start and end times. The commit includes the previously untracked preview.

## Reasoning

The supplied annotated screenshot establishes the intended location above the passage. A plain line indicates the passage interval without suggesting a moving playhead or seek control. Rank and Play remain in the left rail; title and summary keep their full width; scores remain below. Each line spans its own labeled interval, not the entire recording or a shared duration scale.

## Technical debt

None added to the application. This is a design prototype with synthetic timestamps, simulated playback/navigation, and an existing fixed 280ms single-click delay. It does not implement production audio or native double-click timing. If adopted in the app, use actual passage timing and platform gesture handling rather than porting the mock handlers.

## Notes

Inspected the supplied before screenshot and captured the changed 750px preview in Chrome. Confirmed endpoint labels, duration, omission on title matches, and accessible range descriptions. Activated Play and confirmed the range remained static while the separate playback status changed. Earlier preview validation covered dialog and double-click navigation. Reviewed wording against `docs/writing.md`; `git diff --check` passed. Narrow-width rendering was not revalidated in this update. No Swift files changed, so no macOS release build was required.
