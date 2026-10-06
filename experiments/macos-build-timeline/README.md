---
title: macOS build timeline
date: 2026-10-06
status: active
scope: experiment
---

# macOS build timeline

Compare an empty checkout-local build cache with an unchanged second release build. The profiler copies the current Swift client source, including local edits, into an ignored output directory. It does not replace the development app or clear the original build cache.

Run from the repository root:

```sh
uv run --no-project experiments/macos-build-timeline/profile.py
open experiments/macos-build-timeline/artifacts/timeline.html
```

Choose a new output directory when repeating the experiment:

```sh
uv run --no-project experiments/macos-build-timeline/profile.py --output experiments/macos-build-timeline/runs/repeat
```

The output includes `timeline.html`, `timings.json`, raw Swift task traces, and timestamped build logs. The timeline uses named stages and a shared elapsed-time scale for both builds. It names each Swift package download, version selection, and checkout, then separates compiler preparation, compilation of each Swift target, linking, app assembly, signing, and installer staging. Stage bars show actual periods of task activity, including gaps; the Active time column counts overlapping tasks once within each stage. Stages can overlap, so their times cannot be added. Expand Swift tasks to inspect every recorded task, filter by name, or sort by duration. Raw commands and compiler output remain in the build logs. Failed builds retain their timeline and logs; the cached comparison runs only after a successful clean build.

“Clean” means no Swift client `.build` or `.swiftpm` directory. Operating-system caches and remote infrastructure are outside this definition. “Cached” means the same source and build directory immediately after the clean build. It does not model an incremental build after a source change.

Script-stage boundaries come from observed commands and include shell overhead. Swift-stage positions are aligned approximately to the observed build-start message; task durations come from the trace. Compilation target names are matched against filenames in the measured source copy. Keep that copy to retain target names when regenerating the report. Compiler output timestamps measure message arrival, not individual parallel task execution. The script measures compilation, bundle assembly, signing, and installer staging. Finder interaction is excluded. Swift 6.4 or later with `--experimental-trace-events-file` support is required. The flag is injected only into the disposable source copy. Task durations come from Swift build-system events; their start times use the trace origin after package resolution.

Regenerate the report after changing its presentation:

```sh
uv run --no-project experiments/macos-build-timeline/profile.py --output experiments/macos-build-timeline/runs/repeat --render-only
```

For a stable comparison while other work edits the source, pass `--source committed`. This profiles `HEAD`; the default includes current working files. The report records the source choice, commit, and toolchain.

Native audio libraries are built from checked-in archives: Ogg 1.3.6, Opus 1.6.1, and opusfile 0.12. The build does not download these archives. Their combined build interval is recorded; individual library intervals are unavailable in the existing measurements. Swift package intervals use paired output observations, and unobserved manifest/startup time stays separate.
