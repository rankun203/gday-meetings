---
date: 2026-09-22
title: Publish GdayMeetings container package
status: in-progress
---

## Problem

The platform had a Dockerfile but no published GitHub Container Registry package
or repeatable release workflow.

## Implemented solution

Version tags validate the package version, release notes, types, and tests, then
publish native Linux AMD64/ARM64 images with SBOM/provenance and GitHub release
notes. OCI source labels link the package to the repository. Compose pulls a
pinned published version; an explicit build override supports source builds.

## Reasoning

GitHub Actions uses its scoped `GITHUB_TOKEN` for registry publication, avoiding
stored personal registry credentials. Native builds avoid emulator-dependent
Node/native-package builds. The pipeline follows GitHub's documented
[Docker publication workflow](https://docs.github.com/en/actions/tutorials/publish-packages/publish-docker-images)
and the reference project's tag/version release architecture. Explicit native
jobs replace the reusable builder because its automatic branch reference
conflicted with manual publication of an existing immutable release tag.

## Technical debt

None added to packaging. Runtime storage and migration constraints remain
documented in the platform architecture guide.

## Notes

Validation passed: seven platform/MCP tests, typecheck, production build, Docker
build, Compose configuration, and actual SDK initialize/list/search against the
packaged `/mcp` endpoint. Publication and remote pull verification pending.
