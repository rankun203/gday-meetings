---
title: Isolate recording meter updates
date: 2026-09-26
status: in-progress
scope: client-macos-swift
---

## Problem

Recording used about 90–108% CPU in the previous session. Its sample showed the main thread in SwiftUI graph updates and display work in 7,662 of 7,672 samples. Meter updates published through `MeetingStore`, invalidating unrelated library and meeting views ten times per second.

## Implemented solution

- `RecordingMeterState` owns the levels and ten-second activity history. Native AppKit surfaces subscribe directly to amplitude updates and change only their layer geometry. SwiftUI observes a separate, deduplicated `RecordingMeterStatus` for source availability, reconnection, and Voice Processing controls. Quiet/receiving transitions remain native and do not invalidate SwiftUI layout.
- `MeetingStore` keeps lifecycle changes observable and retains capture diagnostics without publishing unused text. Elapsed time remains local to the existing one-second `TimelineView`.
- The native bar exposes its current decibel value through accessibility. History animation still follows Reduce Motion and scene activity.
- Regression tests cover publisher isolation, status transitions, history reset, native resizing, accessibility, reconnect state, and saving. The opt-in release benchmark measures synthetic UI, capture processing, and drain-timer CPU without machine-dependent assertions.

## Reasoning

Separating the store publisher reduced real recording CPU to about 22–42%, but still missed the target. A new five-second sample showed 718 of 3,657 main-thread samples in constraint updates, including 683 recalculating the hosting view's minimum size; 1,874 samples were idle. Isolated SwiftUI amplitude changes still caused repeated layout measurement. Direct native subscriptions remove amplitude changes from SwiftUI layout without lowering meter frequency.

Converted capture processing measured about 0.20% of one core per recorded second. Reusing buffers in `TimedAudioWriter` was deferred: the measured cost is small, and changing buffer ownership adds audio correctness risk without evidence of a material CPU benefit.

## Validation

The release benchmark passed all three opt-in tests. Process CPU is expressed as a percentage of one core:

| Synthetic workload | Store isolation only | Native rendering |
| --- | --- | --- |
| Unshown recording window, idle | 5.8% | 4.2% |
| Unshown window, 10 Hz meter delivery | 34.6% | 4.3% |
| Unshown window, forced 10 Hz store and meter publication | 28.5% | 28.5% |
| Native capture processing, per recorded second | 0.07% | 0.05% |
| Converted microphone processing, per recorded second | 0.23% | 0.20% |

UI intervals were three seconds idle and five seconds per update scenario, after warmup. Capture processed 60 seconds of synthetic audio. The benchmark leaves 2 ms of drain time per 0.1 recorded second so accelerated input does not overflow the writer's bounded ring. Capture scheduling is unchanged. Empty 10 ms and 20 ms drain timers measured 0.24% and 0.13% CPU. These results support the layout diagnosis, but exclude hardware capture and voice processing and do not establish the under-20% real recording target.

After the user resolved Keychain authorization, the installed app recorded 60.943 seconds from the built-in microphone with Voice Processing on and quiet system audio. Both Opus files saved (246,842 microphone bytes and 16,569 system bytes); no transcription ran. CPU samples ranged from 21.7% to 42.3%; after stopping, idle CPU was 0.0–0.1%. This was the first store-isolation build.

The next native-rendering build recorded and saved about 2:27. Its first seven CPU readings averaged 19.5% (13.6–28.2%); a second window ranged from 19.9% to 34.9%. It therefore did not reliably meet the under-20% target. The new sample showed the main runloop waiting in 2,727 of 3,221 samples, about 160 samples measuring hosting-view minimum size, and 265 samples in Apple's Voice Processing on its audio thread. Display-link callbacks used 165 samples, many waiting for render-message delivery. These are sampled stack counts, not a precise CPU breakdown.

The remaining amplitude threshold transition was removed from the SwiftUI status projection: fluctuating across -60 dB affects only native loudness descriptions and accessibility, not source availability or layout. Regression coverage verifies both the suppressed publication and the retained native quiet description. Validation of this final refinement is coordinated with the main task; a reliably under-20% hardware result is not yet established.

Final integrated validation passed formatting, lint, Preview packaging, and all 217 tests. The recording tests include status isolation and native resize/accessibility regressions. Installer staging passed before the final native refinement. Command Line Tools linker warnings about missing search paths remain; no deprecation warnings were encountered.

Preview checks covered synthetic meters and meeting detail, System appearance in dark mode, Light appearance in recording setup, and Escape dismissal. Preview's synthetic meter still uses the legacy SwiftUI bar, so those checks do not validate native live rendering. Hardware inspection will check the production surfaces. Other hardware routes and acoustic quality remain unverified.

Apple's current [NSAccessibilityProtocol documentation](https://developer.apple.com/documentation/appkit/nsaccessibilityprotocol) supports customizing accessibility properties on `NSView` with setters. The new bar uses the [level indicator role](https://developer.apple.com/documentation/appkit/nsaccessibility-swift.struct/role/levelindicator), a numeric value and bounds, and a descriptive value for decibels and source status. No deprecated API was added.

## Technical debt

- The existing conversion path allocates channel mapping and output buffers per converted callback. Its measured CPU cost does not justify changing it here. If a future profile identifies these allocations as significant, reuse buffers under the writer lock and test changing formats, growing frame counts, and resampler resets across outages.
- UI Preview retains its prior SwiftUI bar while live recording uses the native bar. This keeps the preview simulation unchanged during the measured fix, but Preview cannot detect live-rendering regressions. Migrate the simulation to `RecordingMeterState`, then remove the legacy bar when its source-state scenarios use production subscriptions.
