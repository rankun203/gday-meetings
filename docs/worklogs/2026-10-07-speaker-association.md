---
title: Consolidate speaker labeling and separate association
date: 2026-10-07
status: complete
scope: swift-app
---

# Problem

Two providers repeated Community-1 setup across three model sections. Association was presented as a model and provider capability, although it matches compatible voice embeddings with reviewed People Library samples. Separate runtime leases also loaded duplicate Community-1 graphs.

# Implemented solution

One Speaker Labeling provider contains Nemotron and the full Community-1 package. Live labeling requires both; recorded labeling requires only Community-1. Association is an app-level preference under Recording and After Recording, without a provider picker or download section. Existing compatible embeddings can be matched without loading a model.

The model manager shares resident Community-1 graphs across live extraction, recorded labeling, and voice-library preparation. Concurrent requests join one load; a full request loads only graphs missing from an active embedding lease. The manager releases its cache when the final lease ends. Community-1 inference is serialized to protect shared Core ML instances.

Settings migration merges old providers, preserves selected presets and effective enabled capabilities, and maps retired IDs for queued jobs. Association migration preserves effective opt-in. The retired embedding-only installation is folded into Community-1; files are verified before use and incomplete packages require the remaining files.

# Reasoning

The supplied and captured provider screens showed the duplicated model cards. The final design uses one sidebar provider with Live Speaker Labeling and Recorded Speaker Labeling controls, separate readiness rows, and exactly two model sections: Nemotron and Community-1. General contains association behavior only.

The matching algorithm is independent of providers, but embeddings still require compatible model identities, revisions, representations, dimensions, and normalization. The existing compatibility checks remain. Shared instances require serialized synchronous predictions, as specified by Apple's MLModel documentation. An ongoing recorded-labeling job can delay live embedding extraction until it releases this permit.

# Technical debt

Compatibility migration remains for old provider IDs and the retired model folder. Aliases allow queued jobs to survive without rewriting the task database. They can be removed after a future minimum settings version and task migration guarantee that no retired IDs remain. The model-folder migration can be removed when supported installations no longer contain that layout. No duplicate model installation or runtime cache is retained.

# Notes

Validation on October 8: 142 focused tests in 16 suites pass, including shared graph loading, lease removal protection, inference serialization, old settings migration, provider health, task scheduling, and typed matching. Formatting, lint, and diff whitespace checks pass. The isolated `make build-macos` release build passes, including bundle signing and platform verification (macOS 26.0 minimum, SDK 27.0, arm64).

The final isolated preview was captured and inspected in light and dark appearances. It has one Speaker Labeling entry, two model sections, and no association model section or capability picker. Checked the 21.6 MB full package, missing-model explanations, General repair navigation, keyboard preset selection, saving and retaining that preset, association independence across tab changes, and duplicate-provider prevention. These match the intended design.

The commit uses the validated isolated source snapshot; concurrent unrelated working-tree edits are preserved. The running application and user recordings are unchanged. Fixtures are synthetic. Real downloads, live model accuracy, and process memory usage were not measured; tests establish shared loader behavior rather than an RSS measurement. The installed Command Line Tools linker reports absent Developer/usr/lib and Developer/Library/Frameworks search directories. No deprecation warnings appeared. This toolchain warning remains external to the change; recheck after installing a complete matching Xcode toolchain.
