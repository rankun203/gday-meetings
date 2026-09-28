---
title: Provider data folders
date: 2026-09-27
status: implemented
scope: swift-provider-storage
---

## Problem

Model and language caches shared root-level JSON files. Updating one provider rewrote every provider's cache, and provider-owned data had no common location.

## Implemented solution

Store metadata under `providers/<provider UUID>/models.json` and `languages.json`. Load entries on demand, validate their provider ID and endpoint fingerprint, and atomically save only the changed provider entry. Cache files use private permissions. Removing an obsolete cache leaves other provider data intact. Old root-level caches are not migrated; metadata can be fetched again.

## Reasoning

The configured provider UUID remains stable across renaming and avoids filenames derived from credentials or endpoints. Caches are disposable and do not require a compatibility bridge.

## Technical debt

Cache write failures retain the existing in-memory fallback. They are not fatal because metadata can be loaded again. No new compatibility or schema debt.

## Validation

Checks for per-provider paths, endpoint invalidation, preservation of neighboring provider data, ignoring root-level cache files, and read-only libraries passed in the integrated suite: 365 tests across 73 suites. Preview build, formatting, lint, and diff checks passed. Existing Command Line Tools linker-search-path warnings remain. Old production cache files were not altered; the new build creates the provider folders when metadata is fetched.
