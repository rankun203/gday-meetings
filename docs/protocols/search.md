---
title: Search protocol
date: 2026-09-26
status: proposed
scope: capability-contract
---

# Search

## Purpose

Search selected meeting transcripts and summaries through a provider. Local library search remains available without a provider.

## Contract

Indexing input contains a stable meeting identifier, source version, title, and the selected transcript or summary text. Queries contain search text and optional scope or result limits. Original audio is excluded. Sending text for [summarization](summarization.md) does not authorize indexing it.

Results contain meeting references, matching passages, source versions, and the provider identity. Ranking scores, when present, are meaningful only within that provider. Distinguish remote results from local matches.

Follow the [shared provider rules](README.md). Enabling Search requires an explicit selection of content to upload. Future meetings and automatic updates require separate choices. MCP grants are independent of this capability.

## Operations and results

| Operation | Result |
| --- | --- |
| Add or update selected text | Acknowledged source version and indexing state. |
| Inspect indexing | Pending, indexed, failed, or deletion pending. |
| Query | Authorized meeting references and matching passages. |
| Retrieve a match | Authorized source text or a not-found response. |
| Delete indexed content | Confirmation that source text and derived indexes were deleted, or pending deletion. |

Updates must not replace a newer indexed version. Retries use stable identities. Deletion includes derived embeddings and caches; stopping updates is not deletion. Explain partial indexing and unavailable results without reporting an incomplete index as current.

## Swift interface

`SearchProvider` declares the proposed `search(query:)` extension point. Results contain a meeting ID, optional external ID, title, and excerpt. The Swift app has no remote search adapter or remote library screen. Its library search reads local meeting content.

`SearchIndexProvider` extends that query contract with `index` and `remove`. Index documents carry a meeting ID and revision. Indexing status and result versions require further interface work. No indexing adapter is implemented yet.

## Website API reference

The Gday Meetings website exposes authenticated meeting-text search for its own clients. The native Swift app does not call that endpoint. See its [API reference](../../apps/server/docs/api.md) and [MCP documentation](../../apps/server/docs/mcp.md). The existing workspace is shared; this capability does not establish private per-person storage.

The full versioned indexing and deletion contract above remains a target. Existing archive uploads create snapshots and do not continuously synchronize later edits. An adapter must expose only operations supported by the connected website. A successful connection check must not upload content or issue a query containing meeting text.
