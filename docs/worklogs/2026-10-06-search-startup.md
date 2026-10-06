---
title: Local Search startup measurements
date: 2026-10-06
status: validated-with-measurement-limits
scope: macos-search-startup
---

# Problem

The existing 416 ms search median excludes app startup and rendering. Model-only benchmarks do not establish when an actual app window or its search capability becomes ready.

# Implemented solution

Added an instrumentation generator, event probe, and aggregator in `experiments/embedding-optimization/`, with instructions in `STARTUP.md`. They patch an isolated app copy, recording process-start-relative timestamps for the visible window, semantic SQLite connection, model acquisition, tokenizer, warmup, search readiness, query submission, and native result layout. Product source and the installable build remain unchanged. Receipts contain event names, timing, process IDs, thermal state, and peak resident memory; they contain no meeting or query content.

# Reasoning

Measured a release app with the authorized 366-meeting library and its installed Granite 97M mixed-FP16 model. Automatically Load Search was enabled. Repeated launches are fresh processes with uncontrolled filesystem and Core ML caches, not cold boots. Native result layout is an observable rendering boundary; it does not establish display scan-out time. Initial search preparation opens SQLite without materializing the complete vector index in RAM.

The first observational launch resumed automatic search-index tasks while another app was using the library. Its task journal contained conflict transitions reporting that tasks had changed outside the app. This launch is retained separately, not combined with clean startup measurements. The isolated measurement copy was then rebuilt with opt-in guards disabling task restoration, recovery, execution, external task reload, and index scheduling. Search preparation and retrieval remain unchanged. No task records were manually changed.

# Results

Two clean fresh-process launches, each followed by the same five short synthetic queries, produced the following results. The app requests 100 results; the earlier 416 ms native harness requested five. Both clean runs remained in nominal thermal state. DiskANN work and compilation were paused during these measurements; other user applications remained open.

| Measurement | Clean run 1 | Clean run 2 |
| --- | ---: | ---: |
| Process creation → visible window and completed layout | 1,004 ms | 712 ms |
| Process creation → search ready | 3,552 ms | 3,386 ms |
| Semantic index connection and schema registration | 1.22 ms | 2.15 ms |
| Complete model preparation | 2,502 ms | 2,621 ms |
| Model acquisition, including verification/loading | 839 ms | 850 ms |
| Tokenizer construction | 1,576 ms | 1,673 ms |
| Initial prediction warmup | 86.6 ms | 96.8 ms |
| First query → native result layout | 675 ms | 698 ms |
| Following four queries, median | 490 ms | 493 ms |
| Whole-app peak RSS at search readiness | 933 MiB | 919 MiB |
| Whole-app peak RSS through the queries | 1,030 MiB | 972 MiB |

Across the eight subsequent queries, the median was 490 ms and the range was 458–538 ms. Query timing includes People-name resolution, tokenization, inference, exact retrieval, and native result layout. It excludes typing before submission, delays between automation calls, and physical display scan-out. All ten searches showed results. Queries were “release plan,” “project update,” “testing schedule,” “next steps,” and “customer feedback.” No real meeting text was copied into this report.

The initial observational launch took 1.784 seconds to show its window and 7.489 seconds to become search-ready. Model preparation took 5.635 seconds, including 1.921 seconds for acquisition, 1.674 seconds for tokenizer construction, and 2.039 seconds for warmup. Its first query took 740 ms; the next four took 445–472 ms, with a 454 ms median. Automatic indexing contention makes these unsuitable as isolated component timings. Computer-use launch overhead was also large for this run, but is excluded because timestamps come from inside the app relative to OS process creation.

Tokenizer construction is a substantial startup cost. The earlier standalone encoder numbers omit this step and the app model manager's verification/loading path. Investigation of reusable tokenizer structures and safely cached asset verification is warranted; no such optimization is implemented here. RSS is a whole-process high-water mark, not current memory, physical footprint, model-only memory, or vector-index residency. It must not be attributed entirely to the 60 MB of stored vectors.

# Technical debt

None in production. The measurement script uses exact source anchors and intentionally fails when those anchors change; update it before applying it to a different implementation. Instrumentation writes small local receipts and adds some overhead. Disabling background jobs isolates search startup but does not represent an app that is concurrently rebuilding its index. Two clean runs and short queries are descriptive evidence, not a tail-latency distribution or a cold-boot guarantee.

# Validation

The isolated `make build-macos` passed after instrumentation and again after the task guards (96.99 seconds for the final rebuild). Signing verification passed. Existing Command Line Tools linker warnings about missing Developer library/framework search paths remain; no new warning category was observed. Python scripts passed syntax checks and the probe passed Swift formatting/lint. UI interactions used the actual app and real index; only the measurement app was quit between runs. Aggregate receipts are `startup-measurements.json` and `startup-observed-measurements.json`. The signed measurement bundle and content-free raw receipts remain in ignored `tmp/search-startup-measurements/`; its generated dependency caches and isolated source copy were removed after validation. No commit or push was made.
