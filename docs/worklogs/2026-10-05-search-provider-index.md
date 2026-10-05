---
title: Shared index and search providers
date: 2026-10-05
status: in-progress
scope: swift-storage-and-search
---

# Problem

Library, directory, and task indexes had independent SQLite lifecycles and recovery rules.

# Implemented solution

`IndexDatabase` owns one database with independently versioned modules, separate serialized connections, prepared statements, staged rebuilds, and coordinated corruption recovery. A bundled template generates `index.db.md` beside the database. Source files remain authoritative; custom and cloud libraries keep SQLite in a local cache.

Meeting-folder resolution checks committed quarantine before cached locations through an independent reader. Search parsing uses the validated folder during duplicate recovery. Staged rows do not update shared location hints.

# Reasoning

One owner prevents conflicting database-wide schema versions and unsafe replacement of a live database. Staging keeps source decoding outside the writer transaction; module revisions reject stale publication. An independent committed reader keeps source resolution available during rebuilds.

# Validation

The complete feature snapshot passed 914 tests across 160 suites in 129.989 seconds. This includes deterministic stale-cache quarantine and committed reads during a 500-row stage. Its production release passed in 221.92 seconds with no warnings using full Xcode, Swift 6.4, SDK 27.0, and a macOS 26.0 minimum. Search integration is recorded in the next incremental commit; these results validate the combined snapshot.

A 20,000-row publication took 58.37 ms; maximum concurrent read was 1.41 ms and task-write delay was 61.81 ms. This excludes full-text payload volume and model work.

# Technical debt

Atomic publication still copies staged rows under the writer lock. Larger projections need measurement before generation switching or another storage layer. Obsolete separate caches remain untouched until a safe stopped-app cleanup. Existing full directory editing catalogs remain unbounded. No persistent L2 database was added.
