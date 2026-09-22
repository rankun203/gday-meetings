---
date: 2026-09-22
title: Remove shared service authentication and publish 0.3.1
status: release-ready
---

## Problem

The newly built platform retained an unnecessary shared service key that bypassed canonical user authorization and enabled manual task orchestration.

## Implemented solution

Removed GDAY_API_TOKEN from runtime authentication, environment schema and deployment examples. Platform operations require scoped OAuth and Payload access checks. Task creation always queues Gday-owned transcription with required idempotency and signed uploaded audio. Removed execute mode, public PATCH and client result-sink responses. Worker output callbacks retain per-task HMAC capabilities. Updated client contract and release version to 0.3.1.

## Reasoning

Gday owns user management and transcription; a second global client credential has no justified consumer. Worker capabilities authorize only their specific operation. Existing standalone filedrop in meeting-notes is a separate deployment mode, not a Gday fallback.

## Technical debt

None introduced. Existing identity provider and worker limitations remain documented in their original worklogs. Historical mentions of service compatibility describe previous releases; 0.3.1 removes that path.

## Notes

Client and server must be upgraded together because obsolete execute requests are rejected. No schema migration added. Validation: 24/24 tests pass, TypeScript and production build pass, complete diff reviewed. Release publication and container smoke results follow after tagging.
