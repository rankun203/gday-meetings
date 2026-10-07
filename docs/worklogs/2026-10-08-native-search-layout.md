---
title: Native search result layout
date: 2026-10-08
status: complete
scope: macos-search
---

# Native search result layout

## Problem

Search rows stretched excerpts across the available window, repeated title matches, and placed Open far from the text. The approved HTML design separates playback, metadata, and excerpts and shows each match's position in its recording.

## Implemented solution

The native results table uses a centered column up to 750 points wide. Rank and Play occupy a left rail; title and summary sit above source/date metadata and a narrower excerpt column. Optional ranking scores remain last. Single click previews a result in a sheet; double-click and Return navigate. Play bypasses the double-click wait and cancels a pending preview.

A static timeline uses the indexed recording duration and the source interval. Title matches highlight the entire recording, play from zero, and show no duplicate excerpt or “Title match” label. Semantic results retain their full window endpoint. Text results carry saved transcript endpoints in the disposable search index. The library module advances to version 4 and rebuilds its own derived tables; unrelated provider modules remain intact. Missing or invalid timing metadata omits the range rather than inventing an endpoint. Playback does not change this indicator. Timestamp strings and text measurements are cached, unchanged range/style values do not request drawing, and table updates compare presentation inputs before reloading. Timeline preparation makes one pass through the results using indexed meeting metadata.

## Reasoning

The existing reusable native table preserves search paging, keyboard navigation, selection, and scroll restoration. The system double-click interval distinguishes preview from navigation. Metadata loading remains separate from the immediate Play action. The existing semantic metadata already contains endpoint times. Text search now indexes endpoints as well, avoiding per-page transcript file reads.

## Technical debt

None. Endpoint data travels through both indexes. The text index uses its existing versioned rebuild mechanism rather than maintaining an old-schema compatibility path.

## Validation

Before editing, inspected the existing isolated synthetic Preview in light appearance: Text search showed full-width rows, repeated titles, distant Open controls, and no Play for meeting matches. The concrete target follows the approved HTML design and the layout above.

Added focused checks for full-recording title ranges, title playback at zero, invalid timing, clipped bounds, unavailable endpoints, complete semantic windows, and provider audio ranges. Added index-only endpoint and module-upgrade checks, plus a native view test verifying that 100 unchanged timeline configurations and repeated selection styling cause no drawing invalidation. The first regression fixture used AppKit’s asynchronous dirty-region state; it was replaced with a test-only view subclass that counts actual invalidation requests. All 33 targeted tests across six suites pass, including 100 identical timeline configurations requesting zero redraws. Strict Swift formatting and `git diff --check` pass. Release validation uses an isolated checkout so the running development bundle and unrelated work remain untouched. `make build-macos` passed, including packaging and signature verification, targeting macOS 26 with SDK 27. The final build reported no compiler warnings or deprecations.

Captured the changed synthetic Preview in dark and light appearance, including a narrower 900-point window. Checked full-recording meeting ranges, proportional transcript intervals, missing timing on untimed notes/summary results, immediate Play without a dialog, single-click preview and Escape, double-click and Return navigation, and restoration of selection and viewport. The timeline remained static while the separate player advanced. Selection testing found insufficient timeline contrast in light appearance; the drawing now uses AppKit’s selected table/list text color. A fresh release Preview confirmed white endpoint labels and a distinct range on the blue selected row. Transcript Play began at the indexed one-second start without opening a preview.

Validation limits: the Preview uses synthetic silent audio, so these checks establish playback state and seek behavior rather than audible-start latency. Live semantic search could not run because the local model lacked its required LICENSE file; semantic endpoint projection and ranking were covered by tests. No large-library performance benchmark was performed.
