---
title: Preserve speaker identity construction on supported compilers
date: 2026-10-08
status: local validation passed
scope: macOS release compatibility
---

# Speaker identity initializer

## Problem

The macOS 26 CI release build rejected the synthesized `LiveObservationIdentity` initializer because private stored properties made it inaccessible to the capture controller. The newer compiler used by the macOS 27 runner accepted that call, so local validation alone did not expose the incompatibility.

## Implemented solution

Declare the intended internal `init(meetingID:)` explicitly. Private state retains its existing defaults. This does not change identity decisions, persistence, or model behavior.

## Reasoning

An explicit construction interface avoids relying on compiler differences in synthesized memberwise initializer access. The fix is independent of the pending speaker pipeline changes.

## Validation

The earlier macOS 26 failure and macOS 27 success were verified in the same CI matrix. The local focused integration run passed 75 tests across 8 suites in 2.151 seconds with the explicit initializer. The supported release matrix must verify the compiler-specific fix after push.

## Technical debt

None.
