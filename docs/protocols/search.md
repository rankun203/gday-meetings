---
title: Search protocol
date: 2026-09-26
status: implementation-in-progress
scope: capability-contract
---

# Search

## Purpose

Search meeting text or original audio through capability providers. Built-in local text search remains available without a remote account.

## Contract

Indexing input contains a stable meeting identifier, source version, title, and the selected transcript or summary text. Queries contain search text and optional scope or result limits. Voice indexing may use explicitly selected original audio ranges. Text-only providers receive no original audio. Sending text for [summarization](summarization.md) does not authorize indexing it.

Results contain meeting references, matching passages, source versions, and the provider identity. Ranking scores, when present, are meaningful only within that provider. Distinguish remote results from local matches.

Follow the [shared provider rules](README.md). Enabling Search requires an explicit selection of content to upload. Future meetings and automatic updates require separate choices. MCP grants are independent of this capability.

## Operations and results

| Operation | Result |
| --- | --- |
| Add or update selected text | Acknowledged source version and indexing state. |
| Inspect indexing | Pending, indexed, failed, or deletion pending. |
| Query | Authorized meeting references and matching passages. |
| Retrieve a match | Authorized source text or a not-found response. |
| Delete indexed content | Confirmation that provider-held copies and derived indexes were deleted, or pending deletion. |

Updates must not replace a newer indexed version. Retries use stable identities. Explicit provider removal includes its derived embeddings and caches; stopping updates is not deletion. Removing an index never deletes authoritative meeting text or audio. Moving a meeting to Trash preserves its folder and artifacts for restoration while removing search eligibility. Explain partial indexing and unavailable results without reporting an incomplete index as current.

## Swift interface

`SearchProvider` declares an asynchronous stream of `ProviderSearchSnapshot` values, each wrapped in the existing data-flow receipt. Requests include a stable request ID, Text/Voice/Fusion mode, result limit, exclusions, and a page cursor. Each snapshot includes provider ID, sequence, ranked results, total when known, next cursor, and a final marker. Final means the requested page has finished, not that the entire library is indexed.

`LocalTextSearchProvider` adapts the existing local index and emits one final snapshot per page. `LibrarySearchSession` uses that adapter while retaining current paging and stale-query protection. Local passage IDs currently come from the disposable index; `sourceRevision` remains absent until source-version projection is integrated. They must not be persisted as authoritative references.

`ReciprocalRankFusion` replaces each provider's previous snapshot, rejects stale/request-mismatched events, counts one vote per meeting per provider, and uses deterministic ties. Fusion uses BM25-ranked text candidates and cosine-ranked audio candidates. Text paging retains the existing cursor behavior; ranked search returns a bounded set of the best meetings, deduplicating before the limit. Provider failures remain visible while other providers finish. Cancellation and request IDs prevent old queries from replacing current results.

`SearchIndexProvider` adds indexing and removal. The local voice provider stores pinned-model, source-digest, and audio-range embedding artifacts inside the meeting folder and projects them into namespaced tables in the shared `index.db`. Indexing is explicit, resumable, and cancellable. Rebuilding from saved artifacts does not load a model. Queries exclude missing or changed sources and return a playable original-audio range. They do not create People assignments. Remote adapters are not implemented. Providers register trusted namespaced schema modules through the shared database layer; remote responses never contain executable schema SQL.

Text, Voice, and Fusion are connected to the search interface. Voice requires an explicitly configured local Python worker and prepared model folder; neither is bundled with the app. Fusion requires both text and voice providers. The current CLSP model retrieves speech style, not reliable spoken meaning or library person identity. Retrieval quality and large-library throughput remain unvalidated. See [audio model research](../design/2026-10-05-audio-search-research.md) and the deferred [entity-aware retrieval proposal](../design/2026-10-05-entity-aware-voice-search.md). Maintainers may train a reusable model later; end users only encode and index their library.

## Website API reference

The Gday Meetings website exposes authenticated meeting-text search for its own clients. The native Swift app does not call that endpoint. See its [API reference](../../apps/server/docs/api.md) and [MCP documentation](../../apps/server/docs/mcp.md). The existing workspace is shared; this capability does not establish private per-person storage.

The full versioned indexing and deletion contract above remains a target. Existing archive uploads create snapshots and do not continuously synchronize later edits. An adapter must expose only operations supported by the connected website. A successful connection check must not upload content or issue a query containing meeting text.
