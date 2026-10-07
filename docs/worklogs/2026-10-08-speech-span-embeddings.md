---
title: Correct normalization of short voice samples
date: 2026-10-08
status: active
scope: swift-speaker-association
---

# Problem

The pinned FBANK model centers features across its entire ten-second input. Padding a two-to-five-second speech excerpt with zeros therefore changes the mean of its real speech frames. The later speaker mask excludes padded pooling positions but cannot undo that feature offset before the convolutional encoder. An audit reproduced retained vectors from their exact saved audio timestamps above 0.9999 cosine similarity, ruling out a substantial timestamp-indexing error in the tested excerpts.

# Implemented solution

`CommunityVoiceEmbeddingExtractor` now centers each mel bin over real STFT frames and zeros inactive feature frames. It validates the pinned model shapes and uses the graph's 400-sample frame and 160-sample hop geometry. The existing downstream mask mapping is unchanged.

New samples use `gday-span-feature-center-v2`. Existing `gday-span-mask-v1` vectors and worker representations retain their original compatibility identities; they are never relabeled as corrected vectors. Live extraction, saved-audio extraction, and voice preparation use the new contract with the same pinned model assets. An older preparation job rejects a newly returned incompatible representation rather than reporting a false successful completion. Existing reviewed assignments remain intact; compatible new matching profiles require preparing corrected examples from retained audio.

# Reasoning

Normalization must describe real speech, not the amount of padding required by a fixed model input. Correcting features before the convolutional encoder addresses that mechanism directly. A separate compatibility version prevents comparisons between substantially changed representations. This is a preprocessing correction, not evidence that any particular clustering threshold or person-association threshold is calibrated.

# Validation

- Three focused tests cover offset invariance, zero inactive frames, exact duration geometry, malformed features, and preservation of old compatibility identities.
- Additional tests cover preparation capability selection, old-vector round trips, incompatible matching, and older discovery jobs returning a new representation.
- The actual corrected extractor compiled and processed four fixed recorded excerpts. Across the same pairs, the original shared-direction similarities of 0.776–0.936 became 0.069–0.507 after correction. Those four pairs establish the mechanism's effect, not speaker accuracy.
- Re-extracted 775 retained spans without changing sample IDs, times, or activity. Independent-excerpt consolidation still failed accuracy validation after B-only recalibration; it is not a supported automatic method.
- The integrated application passed 1,140 tests. Final release and UI validation continue with the broader speaker-pipeline work before final delivery.

# Technical debt

None introduced. Compatibility identities preserve real differences in preprocessing; they are not a temporary schema bridge. Historical vectors remain readable and reviewed names are preserved. Re-preparing old examples is an explicit operation because changing their vector identity without recomputation would be incorrect. Retuning person-matching thresholds requires a separately labeled validation set; this change does not claim that validation.
