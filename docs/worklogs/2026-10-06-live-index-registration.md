---
title: Preserve live library index registrations
date: 2026-10-06
status: validated
scope: swift-library-folder-resolution
---

## Problem

The full test suite exposed a live library index disappearing from the folder resolver's registry. Registration used an NSCache limited to 32 library roots. Concurrent libraries could evict a registration even while its index remained alive, losing the intended fallback after a newer transient index closed.

## Implemented solution

MeetingFolderLocation now keeps a locked dictionary of weak index references. Registration and lookup prune dead references and remove empty roots. Every live library remains registered; the newest live index for a root remains preferred. The registry does not retain indexes or database connections.

## Reasoning

Registration is a lifetime relationship, so arbitrary cache eviction is inappropriate. Weak references preserve the existing ownership model. Pruning on each operation prevents abandoned roots from accumulating across continued registry use. The separate cache of resolved meeting folder names is unchanged.

## Validation

A synthetic regression creates 40 simultaneous library indexes, checks every registration, releases one, and checks that its weak reference disappears while the other registrations remain. The existing transient-index fallback test remains unchanged. Formatting, compilation, and the 40-root and transient-index fallback tests passed in the 987-test full-suite run. The final split-validation run passed all 987 tests outside one separately validated, timing-sensitive live-transcript test. There were no compiler warnings, and global formatting checks passed.

## Technical debt

None. Registry cleanup scans the live root set on each operation; the set normally contains only the active library and temporary background readers. No fixed cap can discard a live registration.
