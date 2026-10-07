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

`SearchProvider` declares an asynchronous stream of `ProviderSearchSnapshot` values, wrapped in data-flow receipts. Requests include a request ID, query, retrieval mode, result limit, tag exclusions, paging cursor, and distinct unambiguous People IDs. Snapshots include provider ID, sequence, results, total when known, next cursor, and a final marker. Final means the requested page has finished, not that the library is fully indexed.

`SearchIndexProvider` adds `prepare`, `updateIndex(meetingID:rebuild:progress:)`, `resetIndex`, `removeIndex`, and `unload`. Updating creates a missing index or replaces changed content. Progress reports completed and total passages for the current meeting. Operations support Swift task cancellation. Adapters own their input formatting, model identity, and source revision checks; UI code does not embed or rank content.

Local Search uses Core ML Granite models selected from a versioned catalog. The shared local model manager handles downloads, verification, manual installation, and model leases. The old Local Voice Search configuration migrates to Local Search; CLSP embeddings are never reused for semantic retrieval. Text search remains available through `LocalTextSearchProvider` without a model. Legacy voice/fusion adapters remain only for experiment compatibility and are not offered in the app.

Local Search preserves the complete query and embeds it once. Independent People matching contributes a soft speaker preference using confirmed associations in each result window: cosine similarity plus the configured boost times distinct matched speakers divided by distinct identified query people. The bonus is zero with no identified people. Ambiguous names do not boost, and names never filter results. Apply the score before the result limit; retain separate windows from the same meeting. Results expose the score components for inspection.

Each model space identifies its model, conversion, tokenizer, pooling, context limit, normalization, and window policy. Portable artifacts live under each meeting's `providers/local-search/<space-hash>/embeddings.packed`. This binary property list contains metadata and packed INT8 and little-endian FP32 byte arrays. Namespaced SQLite tables project per-window packed blobs, metadata, tags, and confirmed speaker associations into the shared disposable `index.db`. Source fingerprints exclude stale or deleted meetings at query time. Updates reuse unchanged text embeddings within a space and publish an entire meeting atomically. Different spaces never share vectors.

The selected provider is indexed through managed background tasks after model installation, model selection, or saved meeting changes. Saved live checkpoints contain finalized text; partial recognition hypotheses are not indexed. Data presents separate Library Index and Search Index controls. Rebuild restores the projection and updates changed embeddings. General controls startup preparation, and activating Search prepares a model on demand. Background index tasks also require the model; disabling startup preparation does not disable indexing.

Remote search adapters are not implemented. Providers register trusted schema modules through the shared database layer; responses never contain executable schema SQL. Local Search uses an INT8 HNSW graph (USearch 2.26.4, cosine, connectivity 32, construction breadth 128, search breadth 2,000). Retrieve up to 1,000 candidates after tag exclusions, union all windows for identified speakers when boosting is enabled, recompute similarities using SQLite FP32 blobs, apply the speaker bonus, then return at most 100 passages. Decode display metadata only for final results. Stale meeting sources are rejected and the candidate budget is refilled. Approximate content candidates can still miss relevant passages; the benchmark reports recall rather than promising exact rankings.

Graph files under `.index-search-graphs/` are disposable caches. Each records a model-space generation, applied journal sequence, and checksum receipt. A SQLite transaction commits meeting replacement/deletion, both packed vector precisions, and journal entries together. The actor then applies committed additions and removals to its resident graph. Search reuses that graph and holds one SQLite read snapshot. Replay removes a key before adding its coordinates, so repeating a committed operation does not create duplicates.

Whole-graph snapshots are checkpointed after 10,000 changes or 30 seconds, including an idle checkpoint, and on unload. A checkpoint writes a temporary snapshot, atomically publishes it and its receipt, then records its sequence and prunes covered journal entries in SQLite. On restart, load that checkpoint and replay later changes. If a connection falls behind journal pruning, it reloads the published checkpoint. Missing, corrupt, or incompatible snapshots rebuild from packed SQLite rows. Cache-write failure leaves committed vectors and their journal recoverable. Graph persistence is not an independent source of truth; deleting the database still requires projection from meeting artifacts.

Existing development JSON embedding files are converted with the one-time `apps/client-macos-swift/scripts/pack-search-artifacts.py` tool while apps are stopped, retaining a separate backup. The app does not ship an old-format reader. See [integration validation](../worklogs/2026-10-07-hnsw-search.md) and [the index experiment](../../experiments/search-index-scale/RESULTS.md).

## Website API reference

The Gday Meetings website exposes authenticated meeting-text search for its own clients. The native Swift app does not call that endpoint. See its [API reference](../../apps/server/docs/api.md) and [MCP documentation](../../apps/server/docs/mcp.md). The existing workspace is shared; this capability does not establish private per-person storage.

The full versioned indexing and deletion contract above remains a target. Existing archive uploads create snapshots and do not continuously synchronize later edits. An adapter must expose only operations supported by the connected website. A successful connection check must not upload content or issue a query containing meeting text.
