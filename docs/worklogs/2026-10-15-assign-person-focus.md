---
title: Put person search first in assignment
date: 2026-10-15
status: complete
scope: macos-transcript
---

## Problem

The supplied screenshot shows Assign Person opening with focus on the apply-to-speaker checkbox. Typing a name requires another click.

## Implemented solution

Search people is the first interactive control below the heading. The people list follows search, with the apply-to-speaker checkbox below the list. Removed the existing focus binding and default-focus modifier; native popover focus order handles entry.

## Reasoning

Search is the primary entry action. Ordering controls accordingly makes native focus behavior match the task without custom responder code or focus scheduling. The user proposed this layout during review. Explicit SwiftUI focus requests had not overridden AppKit’s checkbox selection in the isolated preview.

## Technical debt

None.

## Validation

Isolated release build passed in 200.29 seconds. The user confirmed that the final search-first layout and native focus behavior pass. Two existing linker warnings reference missing Command Line Tools search directories. Main library unchanged.
