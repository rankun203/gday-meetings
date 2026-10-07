---
title: Search result passage range preview
date: 2026-10-08
status: complete
scope: html-design-preview
---

## Problem

The search layout preview placed passage timestamps in the metadata column, away from their excerpts, and did not show matching duration.

## Implemented solution

Updated `output/search-layout/search-results.html`, the 750px synthetic design preview, with a static whole-recording line above each transcript excerpt. A colored segment shows the matching interval at its proportional position and width. Start and end timestamps sit just outside the segment endpoints so short intervals retain readable labels. Title matches show a fully colored range from 00:00 to the recording duration, replacing the separate “From beginning” label. Whole-recording endpoint labels align inward to stay within the column. Preview dialogs also show the passage's start and end times. The commit includes the previously untracked preview.

## Reasoning

The supplied annotated screenshot establishes the intended location above the passage. A plain line indicates the passage interval without suggesting a moving playhead or seek control. Rank and Play remain in the left rail; title and summary keep their full width; scores remain below. Each neutral line spans the entire recording. The colored segment uses the passage start, end, and recording duration; it has no playhead or seek behavior. Removed the centered duration label to keep the line plain.

## Technical debt

None added to the application. This is a design prototype with synthetic timestamps, simulated playback/navigation, and an existing fixed 280ms single-click delay. It does not implement production audio or native double-click timing. If adopted in the app, use actual passage timing and platform gesture handling rather than porting the mock handlers.

## Notes

Inspected the supplied before screenshot and captured the changed 750px preview in Chrome. Confirmed the neutral line, proportional colored segment, endpoint labels, full-width fill on title matches, and accessible range descriptions including total recording duration. Activated Play and confirmed the range remained static while the separate playback status changed. Earlier preview validation covered dialog and double-click navigation. Reviewed wording against `docs/writing.md`; `git diff --check` passed. Narrow-width rendering and partial-passage labels at the extreme recording boundaries were not revalidated in this update; the whole-recording labels were checked at both boundaries. No Swift files changed, so no macOS release build was required.
