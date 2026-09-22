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
Node/native-package builds. The pipeline follows Docker's documented reusable
[GitHub Builder workflow](https://docs.docker.com/build/ci/github-actions/github-builder/build/)
and the reference project's release architecture.

## Technical debt

None added to packaging. Runtime storage and migration constraints remain
documented in the platform architecture guide.

## Notes

Validation passed: seven platform/MCP tests, typecheck, production build, Docker
build, Compose configuration, and actual SDK initialize/list/search against the
packaged `/mcp` endpoint. Publication and remote pull verification pending.
