---
title: Historical speaker-consolidation evaluation
status: archived after live diarization and retained-evidence consolidation removal
---

# Archived experiment

The user replaced live diarization and retained-evidence consolidation with post-recording Speaker Diarization. Dependent Swift drivers, live model replay/install helpers and their obsolete tests were removed. [RESULTS.md](RESULTS.md) and policy documents preserve historical evidence; their metrics do not validate the replacement architecture.

The remaining Python utilities prepare local source inputs or analyze already-produced JSON artifacts without importing the removed Swift APIs. They do not enable the retired pipeline. For historical evaluation that explicitly accepts a runner, only an existing frozen executable supplied by the caller is usable; this folder no longer builds those executables. Private frozen data and receipts remain under ignored `tmp/`. Use `--help` for input contracts; do not upload private recordings.
