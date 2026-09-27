---
title: Recording toolbar color
date: 2026-09-27
status: implemented
scope: macos-toolbar
---

## Problem and design before implementation

The supplied screenshot shows a gray New Recording icon and label. The toolbar already specifies a red tint, but the native toolbar does not consistently apply it to this label.

Keep the native button, action, keyboard behavior, and disabled conditions. Apply semantic red directly to the label only when the environment says the button is enabled. Leave disabled foreground rendering to the system. The enabled Recording action, which opens the current recording, follows the same rule.

## Implemented solution

A small label modifier reads `isEnabled` and applies red only to enabled content. No recording lifecycle or button availability changes are required.

## Reasoning

Explicit label color addresses the toolbar rendering behavior without using a destructive role or replacing native button chrome.

## Validation

Formatting, lint, and the production build passed. Reviewed the complete LibraryView diff and preserved unrelated export changes. No new tests were added for this styling-only change. The existing Command Line Tools linker warning about a missing Developer/Library/Frameworks search path remains; this change adds no API deprecations. The user subsequently approved the isolated app launch. Enabled/disabled toolbar appearance has not been visually checked because the user is interacting with that app; it was left open. The installed app was not replaced.

## Technical debt

None.
