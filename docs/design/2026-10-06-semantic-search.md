---
title: Local Search provider
date: 2026-10-06
status: implemented
scope: swift-search
---

# Provider and models

Local Search is one local provider with a versioned model catalog. Fresh libraries enable and select it by default. Older settings migrate once to that default; subsequent explicit choices are preserved. Text search remains an optional mode that uses the library index without semantic warm-up or new embedding tasks. Initially support Granite Embedding Multilingual R2 97M and 311M through verified Core ML artifacts. Model choice is independent of the provider capability. Add models through descriptors that specify tokenizer, query and passage formats, pooling, normalization, dimensions, context limits, source revision, and conversion revision. Never infer compatibility from vector dimensions.

Reuse the speaker-labeling model manager for selection, Download, verification, removal, and Manual Installation. Evaluate existing Core ML distributions before adopting them. Where a suitable distribution is absent, prepare a reproducible conversion and a Hugging Face upload folder with tokenizer assets, license, model card, checksums, and validation results. Ask the maintainer to create the repository once the package is ready. Do not publish private evaluation inputs.

# Common search capability

All search providers implement preparation, create/update index, indexing progress, search, cancellation, and removal through one capability contract. Separate query readiness from index coverage. A completed search page does not establish complete indexing. When there is one available provider, select it in General → Capability Providers.

Index identity includes provider/model revision, tokenizer and preprocessing revision, window policy, and source revision. A model selection change schedules a rebuild in the managed task queue; incompatible vectors are never searched together. New meetings, saved transcript changes, and deletions update the selected index in the background. Model selection does not authorize downloading a missing model silently; queue work as waiting for the selected model until installation completes.

Use bounded transcript windows with track, segment, time, and source-version references. During live capture, retain changed-content intent and defer automatic indexing until recording finishes. Then coalesce saved changes, replace changed windows and retain boundary context. Partial hypotheses are not searchable durable evidence. Prioritize capture and query responsiveness over indexing throughput.

Preserve reusable embeddings in meeting folders and project them into namespaced tables in the shared disposable database. Publish coherent generations and invalidate changed/deleted sources immediately. The Data panel presents Library Index (renamed from Index) and Search Index separately, with model, coverage, current task progress, failure recovery, and Rebuild.

# Loading and search field

The first nonempty search edit prepares the index, tokenizer, query model and warmup. Subsequent edits reuse that operation, and Enter awaits it before searching the submitted query. General has no startup-preparation switch. Query and indexing resources have separate lifetimes and generations; indexing independently requests passage resources and defers automatic work during recording. Configuration changes, library changes and shutdown release old resources. General availability checks inspect configuration and file identity, while provider settings perform stronger temporary validation. Heavy preparation and prediction run outside the main actor.

On first Search activation for an unavailable model, show “Download a Search Model” with the selected model name, “Open Local Search Settings”, and “Cancel”. Open the selected provider directly. Do not repeat the prompt for the same model in that window session, interrupt an active download or verification, or show it in Text mode.

Loading feedback occupies the bottom edge **inside** the search field's bounds. Use a thin accent progress fill for measurable work and a restrained moving fill for indeterminate model loading. Clip the drawing to the native field interior; do not draw a bar beneath the field or change toolbar geometry. Preserve native focus, editing, clear, and search controls. Reduce Motion uses a stationary indicator. Accessibility exposes the current loading stage and completion without announcing every animation frame. Errors have a concrete recovery action rather than an indefinitely animated bar.

Before implementing these UI changes, capture the existing Search, Service Providers, General, and Data screens in isolated Preview and record the intended geometry against that evidence.

# Query and speaker preference

Embed the complete original query once, applying only the model's required query format. Retain names and relation words. Remove contextual person-name detection and query rewriting. Match query phrases against People records using the existing name matcher; only unambiguous matches contribute to the bonus. Repeated mentions count once. Duplicate-name matches and uncertain matches contribute nothing.

For each window, calculate:

`score = cosine similarity + boost × confirmed matched speakers / identified query people`

The denominator and numerator count distinct person IDs. With no identified people, the bonus is zero. Use confirmed speaker associations that overlap the window, never attendance. Apply the bonus before top-result selection. Do not filter by person. A query that mentions a person remains searchable through its unchanged embedding.

Provider settings contain “Speaker Match Boost”, range 0–0.2, default 0.1, with this explanation: “Ranks passages higher when identified people in your query speak in them. Set to 0 to rank by content similarity only.”

Expose content similarity, matched/identified speaker counts, bonus, and final score in result details for validation. This is a soft preference: semantics handles “speaks”, “mentions”, and other relationships, and the bonus can hurt some queries. Do not present it as relation resolution or confirmed attribution of the query's claim.

# Validation

Check Core ML/tokenizer parity against pinned source models on synthetic bilingual text, padding boundaries, and supported context lengths. Measure cold/warm load, inference, index updates, cancellation, and recording contention separately. Test model switches during builds/queries, missing models, source edits/deletion, task recovery, and complete-query preservation.

Ranking fixtures cover two-person discussions, mentions, missing labels, repeated names, ambiguous names, and a candidate promoted into the top results by the bonus. Inspect visible score breakdowns. Validate the actual UI in light/dark appearances, keyboard focus, narrow windows, and Reduce Motion. Run the required isolated macOS release build before reporting implementation complete.

# Technical debt

The first implementation scans exact cosine scores one meeting at a time. Measure large-library latency before choosing an approximate vector index; preserve the same provider interface and final speaker scoring when changing the projection.
