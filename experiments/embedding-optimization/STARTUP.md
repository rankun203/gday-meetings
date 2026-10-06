---
title: Measuring Local Search app startup
date: 2026-10-06
status: active
scope: search-startup-experiment
---

# Setup

Copy the macOS client into an ignored isolated checkout. Avoid copying compiler outputs or module caches: they contain absolute source paths. Native audio dependencies and package downloads can be copied or cloned to avoid downloading them again.

Run `uv run --no-project experiments/embedding-optimization/instrument_startup.py <isolated-client-directory>`, then run the normal release build in that checkout. The generator refuses to patch a path outside `tmp` and fails if source anchors no longer match.

Give the generated bundle a unique bundle identifier and display name. Add `GdayStartupReceipt` to its Info.plist with an absolute JSONL output path under an ignored directory. Set `LSEnvironment.GDAY_SWIFT_DATA_DIR` to the authorized library directory. Set `GdayStartupDisableTasks` to true to disable task restoration, recovery, execution, external task reload, and search-index scheduling in the measurement copy. This leaves search preparation and retrieval unchanged and avoids competing with another app that owns the real task journal. Sign the modified bundle locally. Do not replace a running app or the installable release artifact.

Use an already indexed library with the selected model installed and Automatically Load Search enabled. Model acquisition includes file verification and Core ML loading; the tokenizer and warmup are reported separately. The UI currently requests 100 results, while the earlier native validation requested five.

Launch and interact with this app through computer use. For each run, submit the same short synthetic queries through the search field, verify that results appear, and quit only this measurement app. Launch a new process for the next run. Do not clear global caches or stop other applications to manufacture a cold-machine result.

# Boundaries

The probe reads process creation time from `sysctl(KERN_PROC_PID)` and records elapsed wall-clock milliseconds. Window readiness means a titled window is visible and its content layout has completed. Search readiness includes opening the SQLite connection and preparing the model, tokenizer, and first execution plan. Index opening does not load all vectors into RAM; the current exact scan reads passage vectors during a query. Query time runs from the app's submission handler to the native result table's completed layout and loading-state completion. This includes People-name resolution, model inference, retrieval, and UI update; physical display scan-out is not measured.

Repeated launches have fresh in-process state but may benefit from filesystem and Core ML caches. Record thermal state, background contention, per-run values, and ranges. Peak RSS is the process high-water mark from `getrusage`, not model-only memory or current resident memory. No input or result content is written to receipts.

Run `uv run --no-project experiments/embedding-optimization/summarize_startup.py <receipt.jsonl> <aggregate.json> --background-tasks-disabled` to create the aggregate report. Keep an observational launch with background tasks enabled separate; its contention is part of that measurement, not a clean component benchmark.
