---
title: Recording waveform preparation
date: 2026-10-15
status: complete
updated: 2026-10-16
scope: macos-recording-performance
---

# Recording waveform preparation

## Problem

The recording waveform built its bar paths synchronously during native layout. Its representable also replaced the meter subscription on every SwiftUI update, replaying the latest sample even when presentation was unchanged. The same subscription pattern affected the level bar. The typing trace shows broader main-thread layout as the dominant issue; these changes do not establish that waveform preparation caused the typing delay.

## Implemented solution

- Build immutable signal and quiet paths off the main actor from a value-only snapshot. Keep one in-flight operation and one replaceable latest request per surface; skip identical requests.
- Reject stale geometry after sample changes, resize, or teardown. Apply paths and their matching bucket origin together. The display-link callback only computes a scalar offset and updates the layer transform; it performs no bar enumeration, path construction, or task creation.
- Normalize nonfinite amplitudes, dimensions, and timestamps before request comparison. This prevents invalid samples from repeatedly scheduling geometry because a NaN never equals itself.
- Preserve meter subscriptions while the meter identity and presentation configuration are unchanged. A configuration change reuses the subscription; changing the meter disconnects the previous source.
- Preserve the existing waveform size, colors, quiet bars, reduced-motion behavior, and level-bar accessibility. Audio measurement stays in capture callbacks. The main actor retains only the existing bounded scalar history, not PCM analysis.

## Reasoning

[Apple’s SwiftUI performance guidance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance) recommends moving expensive calculations out of view updates and avoiding unnecessary updates. Geometry runs when completed buckets or size change, not on display ticks. The worker retains immutable Core Graphics paths; AppKit appearance resolution and layer mutation remain on the main actor.

Cancellation invalidates a result rather than immediately starting replacement work. This keeps the worker count bounded during rapid updates and teardown. The current geometry is retained until a matching replacement is ready, so old bars never scroll against the new bucket’s timestamp.

## Validation

- Before editing, captured and inspected the isolated synthetic recording preview with Notes open: blue and teal waveform bars above their respective level meters. The intended layout is unchanged.
- Added synthetic tests for signal/quiet geometry, coalescing rapid sample and size changes, rejecting stale and canceled work, completing invalid samples once, and retaining subscriptions across unchanged presentation updates. Async test waits have five-second deadlines.
- The isolated release build passed. All five preparation tests passed in the combined regression run. The changed synthetic recording preview retained the blue and teal waveform layout while typing. No end-to-end frame-time improvement has been measured; the Notes component benchmark is documented separately. Existing Command Line Tools linker search-path warnings remain.
- The installed recording app and main library were not modified or controlled.

## Technical debt

None introduced. The existing bounded scalar history remains on the main actor; moving its small bookkeeping work to an actor would add asynchronous state propagation without evidence that it is material. Immutable Core Graphics paths use an explicit Sendable wrapper because only copied paths cross the worker boundary; mutable builders remain worker-local.

The [integrated commit review](2026-10-16-repository-commit-review.md) records the final full-suite and release validation.
