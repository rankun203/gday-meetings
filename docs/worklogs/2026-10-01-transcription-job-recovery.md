---
title: Transcription job recovery
date: 2026-10-01
status: validated
scope: swift-app
---

# Transcription job recovery

## Problem

Tasks showed a generic HTTP 404 message without identifying whether RunPod or its audio upload provider rejected a connection check. Read-only inspection of the two reported failed task records found no remote job ID. These failures must not be treated as expired submitted jobs.

## Implemented solution

RunPod transcription preflight now identifies the failing connection check and configured provider in its HTTP 404 message. It also states that no transcription job was submitted. The existing status-polling path continues to save `remoteJobExpired` and require an explicit restart when a submitted job returns HTTP 404.

Synthetic regression coverage checks both preflight destinations, preserves manual recovery without marking a job expired, and checks that an older generic status failure only polls its saved job when resumed. A subsequent missing-job response requires an explicit restart; wake recovery does not resubmit it.

## Reasoning

A 404 before submission does not establish that a job expired. Status polling and connection checks have different recovery actions. The saved failure message alone is not used to infer a job's existence or authorize another submission. No real task was resumed, uploaded, or edited during diagnosis.

## Technical debt

Existing generic error messages remain unchanged until the person retries the task. They do not contain structured request-stage information, so rewriting them retrospectively would require guessing the failing operation. A future structured failure receipt could preserve operation identity for historical display. A status-polling 404 establishes that the saved job cannot be retrieved at its saved endpoint; it does not prove the provider's retention policy caused the failure.

## Validation

Existing tests cover missing-job restart, endpoint failures outside polling, uncertain submissions, and durable task recovery. Combined results below include the new regression cases. No real provider request was made.

## Combined validation

Combined validation passed: 517 tests in 96 suites (66.864 seconds), strict Swift formatting/lint, and isolated `make build-macos` (54.65 seconds), including signing. The build retained the documented missing Command Line Tools search-path linker warnings. No new API deprecation warning appeared. The real recording and running app bundle were preserved.

The full passing suite includes both connection-check 404 variants and the legacy saved-job polling regression. Existing user failure records retain their original messages until an explicit retry.

Commit `3ceb78f` was pushed to `master`. [Release CI](https://github.com/rankun203/meeting-notes/actions/runs/36816224156) passed on macOS 15, 26, and 27.
