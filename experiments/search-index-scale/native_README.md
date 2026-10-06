---
title: Benchmarking the current native exact search implementation
date: 2026-10-06
status: validated
scope: search-index-native-baseline
---

# Implementation under measurement

`native_search.swift` is a Swift Testing harness compiled into an isolated release test target with `@testable import GdayMeetings`. It invokes the unchanged production `SemanticSearchIndex.search`, `persist`, and `remove` implementations. It does not reimplement retrieval. Search therefore includes meeting-folder resolution through the registered production Library Index, source-file fingerprint checks, `MeetingListEntry` decoding, full passage-metadata JSON decoding, FP32 Accelerate dot products and norm checks, speaker bonus calculation before top-K, and result construction.

Models, tokenization, People-name resolution, and UI rendering are excluded. Query vectors are the same precomputed 384-coordinate inputs used by the SQLite experiment. This is a retrieval comparison, not total app startup or query latency. The harness records the system SQLite version, process baseline and post-query RSS, peak RSS, physical footprint, CPU time, physical disk I/O, and thermal state.

# Fixtures

Run `native_prepare.py` with the authorized library directory, shared `all.f32`, original `base.f32`, `queries.npy`, mutation `append.f32`, and an output directory beneath ignored `runs/native/`. The script verifies that the library projection still matches the exported base vectors before preparing anything. If the live library changed, `--reconstruct-payload` explicitly permits a representative metadata fixture; it trims windows and splits meetings to restore the frozen corpus dimensions, records the changed source counts, and does not claim the original semantic text-vector pairing. The frozen vectors themselves remain identical across backends. Private inputs and output receipts must stay ignored.

Each scale adds another 366 meetings and 39,066 windows. The harness retains representative real metadata payloads and passage lengths, replacing meeting identities with synthetic UUIDs of the same length. This run reconstructs the original shape from a later library snapshot because the user rebuilt the live index during the experiment. Native JSON encoding produces 23,333,829 metadata bytes per block, 0.080% above the original 23,315,099 bytes. Source files are independent APFS clones with preserved timestamps. The production fingerprint function calculates the fixture fingerprints. The registered Library Index supplies folder mappings; unrelated text-search projections are not populated. The actual search reads the original-size metadata files and passage JSON.

`all.f32` supplies the normalized, perturbed vectors for every scale. One SQLite database grows incrementally from 1× to 10×, avoiding ten complete copies. The source-file clones and database are disposable benchmark inputs. Top-five queries use indices `0, 8, 16, 24, 32, 36, 40, 44, 48, 52, 56`; top-100 measurements also run at every scale. Record tie-equivalent score results separately from strict identity matches because the app uses result IDs to break score ties.

# Run

Copy the client into an ignored isolated checkout, copy this harness into `Tests/GdayMeetingsTests/`, and retain the declared test fixture resource directory. Build the release test target through the repository's `swift_package` helper, with its Swift Testing plugin workaround:

```sh
source apps/client-macos-swift/scripts/common.sh
swift_package test -c release --filter NativeSearchScaleTests \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

Without the benchmark environment variables, the opt-in test exits without reading a library. `native_run.py --checkout <isolated-root> --fixture <fixture-directory>` invokes fresh test processes for fixture preparation and each measured case. Compilation and fixture writes must finish outside query timing windows. Repeated processes have fresh SQLite connections but uncontrolled filesystem caches; do not call these cold-boot or cold-disk measurements.

The result-limit comparison uses a separate fixture directory and preserves the original receipts. Its query tasks end between requests, with a 200 ms idle interval outside timing. Count order rotates between scales. This avoids attributing the continuous-task allocation lifetime described below to normal index residency:

```sh
uv run --no-project native_run.py --checkout <isolated-root> --fixture <fixture-directory> \
  --limits 10 20 50 100 --skip-mutations --separate-tasks --idle-ms 200 --rotate-limits
uv run --no-project native_summarize.py --fixture <fixture-directory> \
  --reference <shared-reference-directory> --reference-prefix truth100 \
  --limits 10 20 50 100 --skip-mutations --output native_limit_measurements.json
```

The `truth100` references validate every requested result count. Strict identity recall and score-equivalent ordering are recorded separately. The result-limit grid does not rerun mutations, which do not depend on the number of returned results.

# Mutations

At every scale, a separate process appends 1,000 prepared vectors across ten synthetic meetings with 100 windows each, then removes those ten meeting records. The append calls production `persist`, including reusable provider JSON artifacts and SQLite projection writes. These are ten meeting transactions, not a single bulk-vector transaction. Fingerprinted source files and request artifacts are prepared before timing. No embedding inference is included.

Validation checks that inserted records are current, a confirmed synthetic speaker bonus is applied before top-K, and deleted records and search results remain absent after reopening the index. Removing source folders is not part of the measured deletion. The fixture is never the user's live library.

# Results and validation

`native_limit_measurements.json` is the completed result-limit comparison: ten corpus sizes × four returned counts × eleven query vectors, with 440 queries. Every requested top-K result set matches the shared exact reference; the largest score difference is 0.000000537, below the declared 0.000002 tolerance. The recorded production search source hash matches the current repository implementation. At 10×, warm retrieval takes 4.26–4.28 seconds across counts, with 172–179 MiB final process RSS. All thermal states are nominal. No embedding model is loaded in these processes.

| Corpus scale | 10 results | 20 results | 50 results | 100 results |
| --- | ---: | ---: | ---: | ---: |
| 1× | 419 ms | 416 ms | 417 ms | 422 ms |
| 2× | 838 ms | 844 ms | 839 ms | 832 ms |
| 3× | 1,237 ms | 1,245 ms | 1,261 ms | 1,248 ms |
| 4× | 1,673 ms | 1,695 ms | 1,658 ms | 1,654 ms |
| 5× | 2,103 ms | 2,115 ms | 2,106 ms | 2,087 ms |
| 6× | 2,537 ms | 2,539 ms | 2,589 ms | 2,572 ms |
| 7× | 2,943 ms | 2,997 ms | 3,008 ms | 3,010 ms |
| 8× | 3,447 ms | 3,406 ms | 3,423 ms | 3,448 ms |
| 9× | 3,877 ms | 3,849 ms | 3,831 ms | 3,847 ms |
| 10× | 4,283 ms | 4,256 ms | 4,275 ms | 4,262 ms |

The table shows warm medians. Corpus size dominates this full-scan implementation; returning fewer results does not consistently reduce its latency. First-query times, every query-length cell, index-open times, and resource counters remain in the aggregate JSON. At 10×, first queries take 4.29–4.40 seconds. These are fresh-process measurements with uncontrolled filesystem caches.

`native_measurements.json` preserves the earlier continuous-task baseline: 20 search cases at top5/top100 and ten mutation cases. That run validated only the first five results and measured 416 ms warm at 1× and 4,043 ms at 10× for top5. Its top100 warm median was 4,070 ms at 10×. The result-limit comparison changes task lifetime and adds idle intervals, so differences between these two runs are not evidence of a production regression. Appending 1,000 windows takes 175–184 ms across scales; removing them takes 2–29 ms. All ten mutation cases pass speaker-boost ordering and deletion/reopen checks. Physical I/O counters measure writes charged during the interval, not all eventual buffered writes.

The initial release build passed in 275 seconds, the memory diagnostic rebuild in 264 seconds, and the full shared test-target build for the count comparison in 440 seconds. Existing linker warnings report missing Command Line Tools Developer framework and library search directories; these did not prevent linking or test execution. No production code changed. Disposable fixture payloads were removed after aggregation; the shared build cache was retained for the following app release validation.

## Memory lifetime

The continuous test task retains autoreleased allocations between its eleven queries. At 10× its reported RSS rises to 1,352 MiB; this is not the index's required resident size. `native_memory.py` runs three queries in fresh tasks with 200 ms between queries, then repeats with a test-only autorelease pool around the unchanged actor method. Both cases return identical result IDs and scores to the baseline.

Separate tasks hold RSS to 151, 155, and 157 MiB; physical footprint after the idle periods is 76, 22, and 24 MiB. The explicit-pool case reports 154, 162, and 167 MiB RSS. Retrieval remains about four seconds. RSS includes allocator-held pages, while physical footprint reflects memory charged to the process; neither is just vector storage. These process counters exclude the OS filesystem cache, which can retain SQLite pages after repeated scans. These diagnostics establish lifetime-sensitive accumulation in the benchmark, not a production memory leak or a measured whole-app steady state. Results are in `native_memory_measurements.json`.

Run the diagnostic against the completed 10× fixture:

```sh
uv run --no-project native_memory.py --checkout <isolated-root> \
  --fixture <fixture-directory> --output native_memory_measurements.json
```

## CPU profile

A separate 15-second Instruments Time Profiler capture attributes 50.8% of CPU samples to JSON decoding, 19.7% to source fingerprint validation, 5.3% to SQLite calls, 0.5% to explicit Accelerate kernels, and 23.0% to other retrieval work. Inlined vector-loop work can fall into the last category; the Accelerate share is not all scoring. This is sampled CPU attribution, not wall-clock stage timing. Profiled queries are excluded from the latency grid. An earlier combined Allocations capture confirmed allocation activity but substantially distorted CPU shares, so the CPU conclusions use only the Time Profiler capture.

Attach only to the isolated `swiftpm-testing-helper` process while the harness runs with `GDAY_NATIVE_SEPARATE_TASKS=1` and a distinct report suffix:

```sh
xcrun xctrace record --template 'Time Profiler' --attach <benchmark-pid> \
  --time-limit 15s --output <ignored-trace-path> --no-prompt
xcrun xctrace export --input <ignored-trace-path> \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
  --output <ignored-stack-xml>
uv run --no-project native_profile_summary.py <ignored-stack-xml> native_profile_measurements.json
```

The full private traces contain environment details and source paths and must remain ignored. The public summary contains only symbols and aggregate sample shares. Export required running outside the filesystem sandbox because Instruments reads kernel metadata.

## Result-table layout

`native_layout_helper.swift` is appended only to the isolated copy of `LibrarySearchResultsView.swift`; `native_layout.swift` is copied into its test target. The helper supplies synthetic rows directly to the production native table, bypassing the coordinator limit only for this measurement. It uses the same 1280 × 720 viewport, excerpt length, summary, date, and control state for 10, 20, 50, and 100 rows. Each case constructs an offscreen host and then calls the production coordinator update with a new generation to measure synchronous table reload. Six repetitions rotate count order; warm summaries exclude repetition zero.

Run the release `NativeSearchLayoutTests` filter with `GDAY_NATIVE_LAYOUT_OUTPUT` set to a path beneath ignored `runs/native/`, then summarize with `native_layout_summary.py <receipt> native_layout_measurements.json`. The test checks that every requested row exists and that visible cells were materialized. It excludes provider retrieval, embedding, the surrounding header, asynchronous summary lookup, scrolling, on-screen presentation, and display scanout. It therefore measures table layout rather than full app rendering latency.

Warm host construction and layout medians are 76.3, 83.5, 80.8, and 80.1 ms for 10, 20, 50, and 100 rows. Reload medians are 2.87, 2.54, 2.60, and 2.80 ms. All cases materialize eight cells in the fixed viewport. The first host costs 165 ms. Within this probe, table virtualization keeps visible-row work nearly constant across counts; this does not establish the cost of the excluded app work.

# Technical debt

No production debt is introduced. The opt-in benchmark retains a representative metadata fixture because the original snapshot changed; its text-vector associations cannot validate semantic relevance. The fixture preparation records this explicitly and checks exact snapshot alignment by default. A future end-to-end relevance comparison must freeze metadata and vectors together. The harness uses a Command Line Tools Swift Testing plugin workaround; remove it when the supported toolchain discovers that plugin without an explicit path.
