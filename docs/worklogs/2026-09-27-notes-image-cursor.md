---
title: Notes image resize cursor
date: 2026-09-27
status: implemented
scope: macos-notes
---

## Problem

The invisible image resize corner was difficult to find. The text view applied an I-beam over images and could overwrite the diagonal cursor after its own hover handler ran.

## Implemented solution

Image hover and native cursor events use the same policy: arrow over the image, diagonal resize pointer over its bottom-right corner. The invisible corner is 32 points wide and tall, clamped to the image bounds. Drag initiation uses the same rectangle. Image-hit cursor and mouse-move events bypass native text cursor handling; image views use the same policy, including during dragging. No permanent handle is drawn.

The editor also accepts panel-border and editing-enabled options for the separate Notes mode-control update. Disabling editing resigns keyboard focus without replacing text or clearing undo history.

## Reasoning

A shared hit region prevents cursor feedback from promising a drag where none starts. Consuming image-hit events prevents competing I-beam writes within the same event. The image body remains an arrow, making the corner transition easier to find.

## Validation

Formatting and lint passed. All 313 Swift tests passed before the final event-consumption refinement (65 suites, 8.405 seconds); the three focused native tests passed afterward (0.149 seconds). The final production build passed (34.59 seconds). Native tests cover clamped corner geometry, read-only images, body and corner cursor routing, and mode changes preserving selection and undo while resigning focus. The user's active app has not been replaced; visual hover and drag checks remain pending. The existing Command Line Tools linker warnings about missing search directories remain; no deprecated API warning appeared.

## Technical debt

The existing macOS 14 fallback uses a diagonal symbol cursor because the system frame-resize cursor is available from macOS 15. Remove that fallback when the minimum supported version advances.
