---
title: Speaker association provider health
date: 2026-10-02
status: implemented
scope: swift-provider-health
---

# Speaker association provider health

## Problem

Nemotron displayed the shared Speaker Association Model but advertised only Live Speaker Labeling. General therefore omitted it from Speaker Association. Its health check also rejected the embedding model as an invalid Nemotron labeling preset. Discovered model files without a preparation receipt required a manual verification action.

## Implemented solution

Nemotron now advertises both capabilities. Existing Nemotron configurations gain the newly available capability once; a stored capability version preserves subsequent explicit disabling. Association checks the shared embedding model independently of the labeling preset. Saved Community-1 labeling accepts either local provider for association because both use the same embedding model.

Opening a model’s provider controls discovers, verifies, and prepares that displayed model automatically. Discovery is scoped to the displayed models rather than every installed preset. Lightweight health checks inspect file metadata and, for installations without a preparation receipt, validate pinned hashes without loading Core ML. Acquisition still verifies and prepares assets before use. Missing or invalid files report their issue through provider health. Verification does not download files. General observes model phase changes, refreshes selected local capabilities and never-configured local capabilities, and applies initial provider selection when they become ready. Explicit None choices and disabled features remain unchanged; unrelated remote providers are not checked. Provider controls remove the redundant Verify action; Refresh also discovers and verifies manually copied files.

## Reasoning

Capability advertisement, health, and runtime selection must agree. Merely showing embedding model controls did not make Nemotron selectable. Keeping the shared model manager responsible for verification avoids duplicating repair behavior in General.

## Validation

Regression coverage includes the legacy capability upgrade, persisted explicit disabling, independent labeling and association health, same-size corrupt copied files, automatic discovery verification, and lease protection. The integrated snapshot passed 661 tests in 115 suites. Formatting, strict lint, and diff checks passed. The isolated release build passed in 139.14 seconds. Native preview showed the Nemotron fixture in Speaker Association, accepted its selection, and retained it after tab navigation. Preview health is synthetic; no real model files or active recording were changed. The reported screenshots establish the original mismatch; no layout redesign was intended. Existing Command Line Tools linker search-path warnings remain; no deprecated API warnings were observed.

## Technical debt

The capability-version field is a compatibility migration for existing provider records. It remains necessary while settings written by older app versions are supported; remove the legacy migration only after that compatibility window is retired. Existing receipt-based health is a readiness estimate; full pinned-file verification still runs before model acquisition. No additional model download or audio data migration is introduced.
