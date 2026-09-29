---
title: Reveal a new recording in the meeting list
date: 2026-09-29
status: complete
scope: swift-meeting-list
---

# Reveal a new recording in the meeting list

## Problem

Starting a recording selected its new meeting while its row remained above the visible list. The supplied recording screenshot showed the selected row clipped at the toolbar boundary. The native list preserves the previous first visible meeting when entries change. Notes creation and audio import publish `latestCreatedMeetingID` to override that anchor deliberately; recording creation omitted that signal.

## Implemented solution

Publish the new recording ID after its metadata saves successfully. The existing native list reveal behavior then shows the entire new row, including when the user was browsing older meetings. Ordinary metadata changes and paging retain their existing pixel anchor. No row spacing, scroll inset, toolbar, or detail layout changes are needed.

UI Preview adds an optional **Start Synthetic Recording** button under `--synthetic-recording-start`. Combined with `--synthetic-pagination`, this permits repeatable insertion after the table has laid out, at the top or after scrolling. It uses generated audio and never opens capture hardware.

## Reasoning

The list's anchor preservation is intentional and remains necessary during cursor-window rotation. Recording should use the same explicit reveal signal as the other meeting creation paths. Changing list spacing or forcing every selection into view would hide the missing creation event and disturb normal browsing.

## Validation

A native table regression recreates the insertion with recording selection but no reveal signal, checks that the viewport moves by a row, then publishes the signal and checks that the complete new row is visible. It also checks that a later title and finalizing-state update preserves the revealed position. All three `MeetingPrefetchTests` passed, including forward/backward paging and bounded prefetch. The final integrated suite passed all 455 tests.

In isolated UI Preview, the paginated list began scrolled to its end. Choosing **Start Synthetic Recording** revealed the complete selected recording row at the top. It remained fully visible while the timer advanced, both sources were muted and unmuted, tabs changed, and the recording was saved. Captured screenshots confirmed the existing row spacing and toolbar boundary were preserved. The build reported existing linker search paths missing from the standalone Command Line Tools installation; it reported no source deprecation warnings.

## Technical debt

None. Synthetic preview recording validates presentation and navigation only; actual capture remains outside this isolated fixture.
