---
title: Investigate sidebar animation CPU use
date: 2026-09-26
status: unresolved
scope: client-macos-swift
---

## Problem

The user reported sidebar stuttering and CPU peaks around 80%. Investigation found repeated SwiftUI/AppKit layout work during column resizing. No tested change reliably reduced that work while preserving the interface. The original animation and title sizing remain in place.

## Implemented solution

Added `SidebarPerformanceTests` and `scripts/measure-sidebar-cpu.sh` for a repeatable diagnostic workload. `LibrarySidebarControl` optionally binds to the existing view state and invokes its actual toggle action. Production views pass no control: the original three `@State` fields, 0.25-second animation, stale-completion guard, delayed row reveal, toolbar placement, and Reduce Motion behavior remain unchanged. An optional initial meeting selection lets the test open an imported transcript directly.

The benchmark yields to the main actor, verifies row restoration and completion timing, and reports process and main-thread CPU relative to one core. It creates a temporary library and opens an unshown 1200 × 800 window. Its default workload has 40 meetings with 50 lines of notes each. An optional authorized legacy fixture is copied into the temporary library; its source remains unchanged. No capture or provider request starts.

```sh
bash apps/client-macos-swift/scripts/measure-sidebar-cpu.sh
GDAY_SIDEBAR_FIXTURE=/path/to/copied/legacy/meeting \
  bash apps/client-macos-swift/scripts/measure-sidebar-cpu.sh
```

## Reasoning and results

The existing code already uses supported SwiftUI animation completion (`withAnimation`, `.removed`), not a delay or timer. A transition token prevents an interrupted animation from revealing rows for an obsolete state. Replacing that callback alone cannot remove the per-frame layout work.

A four-second sample found window layout and nested hosting-view geometry work dominant; meeting filtering and notes persistence were not dominant. The final retained driver measured an authorized copy containing 1,007 transcript segments and about 48,000 characters, with no concurrent compilation or speech-recognition workload.

| Final production-state driver workload | Process CPU | Main-thread CPU |
| --- | ---: | ---: |
| Idle | 6.7% | 4.0% |
| 12 animated toggles over six seconds | 62.1% | 60.6% |
| 12 Reduce Motion toggles over six seconds | 20.8% | 18.9% |

These averages are not directly comparable to the reported 80% instantaneous peak. The unshown-window benchmark does not establish visible frame pacing. All six expansion completions occurred after 0.27–0.31 seconds.

Exploratory trials examined native wrappers, a flat native split, implicit layer animation, SwiftUI column transaction/geometry isolation, and removal of the outer header's fixed-size constraint. None established a safe improvement with the final driver. A sidebar-kind native split item also moved the toolbar. No trial implementation is retained.

Two harness problems were found and corrected. A synchronous loop blocked main-actor completion callbacks. An extracted observable-state model also changed animation behavior when notifications were deduplicated; timing assertions caught skipped animation. Both approaches were removed. Earlier measurements, including the 38.2% exploratory baseline, used those discarded arrangements and are not directly comparable to the final production-state driver. They must not be reported as measured improvements or as the current baseline.

Official APIs reviewed: [SwiftUI animation completion](https://developer.apple.com/documentation/swiftui/withanimation(_:completioncriteria:_:completion:)), [hosting sizing options](https://developer.apple.com/documentation/swiftui/nshostingcontroller/sizingoptions), [AppKit animation completion](https://developer.apple.com/documentation/appkit/nsanimationcontext/runanimationgroup(_:completionhandler:)), and [implicit layer animation](https://developer.apple.com/documentation/appkit/nsanimationcontext/allowsimplicitanimation). No native wrapper or new platform requirement is retained.

## Validation

Both the default synthetic workload and the long-transcript fixture passed row-restoration and completion-duration assertions in the shared checkout. The default workload measured 60.3% process CPU during animated toggles; no CPU threshold is asserted. Formatting and lint passed. The full suite passed 243 tests, including a mounted production-view reversal and Reduce Motion regression test. Independent review confirmed the original state/toggle behavior and the inactive production diagnostic path. Original sidebar UI behavior was retained after rejecting the candidates.

During the later notes integration, concurrent main-actor tests delayed the intermediate reversal observation beyond the animation's end. The suite now always checks immediate reversal state and settled results, and checks the intermediate state only when it resumes within that interval. A separate run with `GDAY_SIDEBAR_STRICT_TIMING=1` requires that interval to be observed and passed the hidden-row, completion, and Reduce Motion checks (one test, 1.137 seconds). The integrated suite passed 305 tests. This changes test scheduling expectations only; it does not improve or change the app's animation.

## Technical debt

Sidebar animation performance remains unresolved. The current width animation still triggers content reflow. A future change needs a demonstrated improvement on this workload plus visible checks for toolbar stability, divider positions, title wrapping, selection, keyboard access, rapid reversal, and Reduce Motion. Rejected implementations remain outside the app.

Existing linker warnings report missing Command Line Tools search paths. A clean isolated third-party configure run also probes the obsolete `-single_module` option; application code does not use it. Retain pinned dependencies until their next refresh, then update the generated libtool configuration. Neither warning is suppressed.
