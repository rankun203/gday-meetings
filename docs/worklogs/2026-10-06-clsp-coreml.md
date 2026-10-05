---
title: Native CLSP inference and conversion evaluation
date: 2026-10-06
status: validated-with-limits
scope: macos-local-voice-search
---

# Problem

Local Voice Search required a separately installed Python worker and model cache. The replacement runs inference in Swift and Core ML, with managed model files and no Python installation for app users. Conversion fidelity must be established independently of whether CLSP's speaking-style embeddings produce useful search results.

# Implemented solution

`CLSPCoreMLWorker` owns native model inference, the RoBERTa tokenizer, and the matching audio frontend. It serializes preprocessing and predictions off the main actor, checks cancellation, normalizes 512-dimensional outputs, and releases model leases after idle use or shutdown. The Swift frontend preserves the upstream 16 kHz mono resampling, Kaldi filter-bank settings, and reflection boundaries. The text path preserves case-sensitive byte BPE, special tokens, masks, and truncation.

The controller uses this native worker. Provider eligibility no longer requires executable or model-folder paths; readiness checks managed files without loading models. The provider form uses shared model download, verification, cancellation, removal, and manual-installation controls, followed by explicit Voice Index actions. Before editing, inspected the isolated Preview's existing form, which required Python paths and showed a missing-worker error. The approved layout retains the provider name, enable switch, readiness, and index actions.

Prepared models are in ignored `tmp/clsp-coreml-2026-10-06/final-v1`. The runtime manifest contains 19 compiled-model, tokenizer, and license files totaling 2,901,317,393 bytes. Source `.mlpackage` files are included separately for recompilation and are excluded from app downloads. The files have been installed in the managed local model directory and verified. No model files or evaluation material have been uploaded. The requested future repository is `rankun203/yfyeung-clsp-coreml`; publication is outside this task.

## Reproducible conversion

`apps/worker-search/scripts/convert_coreml.py` verifies pinned SHA-256 values for source, configuration, tokenizer assets, and the full checkpoint before importing reviewed model code. It modifies only a temporary local package and preserves the original cache. The separate locked conversion environment uses Python 3.12, Core ML Tools 9.0, PyTorch/Torchaudio 2.7.0, and Transformers 4.57.3. The original evaluation runtime remains on PyTorch 2.8.0, which Core ML Tools reported as untested for conversion. Full Xcode is checked before export.

The converter exports both complete encoder projections, transforms, and unit-L2 normalization in float32. Audio accepts `[1,T,128]` features for 25–3000 frames; text accepts `[1,L]` token IDs and masks for 2–512 tokens. Both outputs explicitly have shape `[1,512]`. Float16 is an optional separate experiment, not the prepared distribution's precision. Each encoder export and compute-policy validation runs in a fresh sequential process to bound memory use. Outputs cannot overwrite an existing directory; deterministic manifests record file hashes and sizes.

Three source adaptations address supported APIs and numerical correctness:

- Deprecated CUDA AMP decorators use `torch.amp` in the reviewed conversion copy. Tokenizer/configuration reads use the pinned local files, with no implicit download.
- Relative attention uses equivalent flattened indexes to avoid an ambiguous gather shape during Metal compilation. Explicit output shapes remove a second source of shape ambiguity.
- Swoosh forward helpers use the upstream stable log-add-exp expression instead of an overflowing exponential followed by an infinity-selection fallback. Corpus evaluation exposed seven large embedding errors in the earlier conversion; the corrected expression preserves the original eager result while avoiding the Core ML overflow path.

## App packaging

The release bundle includes `swift-transformers_Hub.bundle`; tokenizer fallback configuration uses SwiftPM's `Bundle.module` and requires that resource even with local tokenizer files. App-only license and NOTICE copies for Swift Tokenizers, Jinja, HuggingFace, Collections, Crypto, EventSource, yyjson, and resolved SwiftASN1 are in `ThirdParty/swift-tokenizer-licenses/` and copied into `Contents/Resources/ThirdPartyLicenses/SwiftTokenizers`. These do not change the frozen model distribution or its 19 asset hashes. The selected macOS Crypto target uses CryptoKit; conditional BoringSSL/XKCP and unselected CryptoExtras are not part of this dependency path.

## Licenses and attribution

CLSP is pinned to `30355ce67960e4cc1562e4e5fa154baf86a21430`; RoBERTa tokenizer assets are pinned to `e2da8e2f811d1448a5b465c236feacd80ffbac7b`. The [CLSP model card](https://huggingface.co/yfyeung/CLSP/blob/30355ce67960e4cc1562e4e5fa154baf86a21430/README.md) and inherited SPEAR XLarge v1 declare Apache 2.0. RoBERTa and its tokenizer assets retain MIT terms. The Swift DSP port retains Torchaudio 2.8.0's BSD 2-Clause terms; Swift Tokenizers retains Apache 2.0. The checkpoint already contains its fine-tuned encoders, so conversion does not substitute newer SPEAR or RoBERTa weights.

`apps/client-macos-swift/ThirdParty/clsp-licenses/` contains full license texts and pinned component, copyright, and modification notices. These are copied into the app's `Contents/Resources/ThirdPartyLicenses/CLSP` and the prepared model distribution. No separate NOTICE file was present in the pinned model repositories. The reviewed terms permit conversion and redistribution with the preserved notices; this does not grant rights to training data, demonstration recordings, or repository artwork, none of which is distributed here.

# Validation

The numerical thresholds were fixed before execution: minimum cosine 0.999 for float32 and 0.995 for an optional float16 experiment. They were not relaxed to accommodate failures.

| Check | Result |
| --- | --- |
| Hash verification and guarded source adaptations | Passed against the original pinned snapshots |
| Float32 activation stress, 2,001 values from −1000 to 1000, both compute policies | Passed; maximum absolute error 0.0000004768 against the original eager fallback |
| 36 encoder checks, `ALL` and `CPU_ONLY` | Passed; minimum cosine 0.9999999999627427, maximum absolute error 0.0000013667 |
| 16 direct compiled-bundle checks, both compute policies | Passed; minimum cosine 0.9999999999798217, maximum absolute error 0.0000008866 |
| Final runtime-file integrity after diagnostics | All 19 hashes unchanged |

Encoder checks include text lengths 2/32/512, random audio features, and deterministic tone/chirp/silence waveforms processed by upstream filter banks at 25/73/1000/2322/2469/2837/2864/2865/2884/2968/3000 frames. Direct `.mlmodelc` checks cover audio lengths 25/73/1000/3000 and one opaque corpus reference at a previously failing length. Synthetic compiled outputs were compared with package outputs; the opaque case was compared with the original reference embedding. An `ALL` pass confirms that policy executes correctly, not that every operation ran on a particular accelerator.

Private evaluation inputs and outputs remain in ignored temporary storage. Tracked fixtures, documents, and UI examples use synthetic content. Native end-to-end evaluation and relevance results are recorded separately from conversion parity.

## Native evaluation checkpoint

The private dataset covers ten summary-derived scenarios, five English and five Chinese, with 50 queries (25 in each language, including 14 cross-language queries). An actual Claude Code Opus 5.5 session delegated dataset generation to Sonnet 5.5; the recorded model usage confirmed both requested models. The corpus contains 50 labeled relevant windows and 100 additional unjudged windows. Those additional windows are not asserted to be irrelevant. Scenario selection and labels are exploratory, not an independently adjudicated benchmark. Private queries, recordings, identifiers, and summaries remain outside version control.

The native harness completed in 297.91 seconds. Across 50 text inputs and 150 normalized 16 kHz clips, minimum embedding cosine was 0.99999994. Maximum component error was 0.000000346 for text and 0.00000104 for audio; maximum similarity-matrix error was 0.00000274. Top-1/5/10 ranking overlap with the reference was 100%. Topic recall at 1/5/10 remained 2%/4%/8%, with mean reciprocal rank 0.05263. This preserves the reference's weak topic relevance; conversion did not make CLSP a topic-retrieval model.

Median native audio inference was 1.385 seconds, with p95 1.756 seconds and first-audio cost 8.567 seconds. Median text inference was 0.074 seconds; first-text cost was 22.834 seconds. These are measurements from this machine and evaluation run, not interface latency guarantees.

The production persisted search also passed all 50 queries with 150 indexed windows and a 100-hit response cap. Top-1/5/10 overlap remained 100%; 48 of 50 complete top-100 lists had identical order, with small lower-rank ordering differences in the other two. At the same 100-hit cap, mean reciprocal rank matched the reference at 0.0511682 and recall remained 2%/4%/8%. The full 150-window matrix above has a different rank depth and therefore a different mean reciprocal rank.

Ten original 48 kHz probes initially showed lower agreement with a reference decoded by SoundFile: minimum cosine 0.99892 and maximum component error 0.00809. The decoder boundary was isolated by feeding the same libopusfile-decoded PCM to the original PyTorch frontend and native path. All ten then passed with minimum embedding cosine 0.999999996 and maximum component error 0.000000272. A separate native PCM-only comparison confirmed identical lengths, minimum cosine 0.999999999999915, maximum sample error 0.0000002384, and maximum RMS error 0.00000001452 against Torchaudio resampling. The difference between independent decoders is retained as a measurement limitation; no threshold was relaxed.

## Remaining compiler diagnostic

`coremlcompiler` exits successfully but logs a BNNS convolution shape-deduction diagnostic for the audio model. The same diagnostic appeared after a successful CPU prediction during teardown. An otherwise identical diagnostic package with only the lower bound raised from 25 to 1000 compiled without the message; default length remained 1000 and the upper bound remained 3000. This isolates short-range specialization, but does not expose the internal operation mapping or exact fallback. Actual compiled predictions pass at the 25-frame minimum on both policies, so the final model retains that supported range.

Conversion logs also retain the dependency's optional palettization docstring warning, Transformers' unused loss-configuration message, tracer shape/constant notices, and embedding training-argument notices. No warning is suppressed. These conversion diagnostics are separate from Swift build results; this conversion is not described as warning-free.

## App integration validation

The final release build and Preview packaging passed with macOS SDK 27.0 and deployment minimum 26.0, including signing verification. No Swift compiler warnings were reported. Packaging includes the Hub tokenizer resource bundle, Crypto privacy resource bundle, FluidAudio resources, and app-only dependency notices. Global Swift formatting passed. Authored-code diff checks passed; the complete staged diff reports only three whitespace notices in unmodified upstream Torchaudio/SwiftASN1 license files, retained byte-for-byte for attribution and model hash integrity.

The main test invocation passed 987 tests. The existing live-transcript final-phrase test passed separately in 0.532 seconds; its real five-second deadline can expire when the concurrent suite starves the main actor. Its implementation and production deadline remain unchanged. Native evaluation and the ten-range decoder diagnostic passed separately with local model assets explicitly enabled.

Captured and inspected the changed provider in isolated Preview in dark and light appearance, with synthetic data and silent playback. The missing-model state shows 2.9 GB, Download, Open Model Folder, Refresh, and Manual Installation. Expanding the disclosure exposes the exact required file layout and future repository link; scrolling reaches the index actions. The layout retains readable labels and the shared settings components. Download and removal were not exercised against the unpublished repository. The production model manager's installed-file validation and compiled prediction passed through the native harness against the real model directory.

Full-app validation used the real data folder after confirming the installed app was idle. Normal release startup waited in the existing `SecItemCopyMatching` credential read. Instead of requiring credentials for local inference, validation restarted with the documented `GDAY_SWIFT_DATA_DIR` override pointing at the same folder, which skips provider-key reads. The managed CLSP files loaded, settings showed Ready, and a Voice query completed through Core ML. The real library has no compatible native voice index yet, so this smoke query correctly returned no matches; the 150-window persisted-search evaluation above measures ranked results. No library-wide audio indexing was started. The local-only process was closed and the original installed app restored afterward; credential-enabled startup of the new ad-hoc build remains unvalidated.

During the first cold setup, the settings view retained Preparing after the preparation receipt had been written and model resources released. Reopening the provider showed Ready, and a subsequent fresh-process check showed Ready on its first selection. A focused regression confirms both Combine publishers emit Preparing → Ready. No speculative timer or manual notification workaround was added. The transient view-refresh issue remains recorded for reproduction under cold setup. The app also emitted an E5RT cache resources.bin diagnostic before a successful query; this was not a missing distribution asset or an inference failure, and its log is retained.

# Reasoning

Reuse the existing local-model manager and setup controls so verification, cancellation, readiness, and removal have the same behavior as other native models. Keep inference and DSP off the main actor. Preserve the original model's preprocessing and complete embedding heads, and diagnose failed numerical cases instead of accepting a looser threshold. CLSP describes speaking style; numerical parity alone does not establish meeting-topic relevance.

# Technical debt

- **Cold setup status refresh:** One first-run view retained Preparing after setup completed; reopening it recovered, and a fresh process passed. Keep the publisher regression and reproduce with a hosted view and controlled preparation delay before changing observation ownership. The current workaround is reopening the provider; no timer or forced-notification workaround was introduced.
- **Legacy settings bridge:** Executable/model-path fields and the metadata validator remain decodable for saved settings and the existing Python reference tooling. Native app inference no longer invokes that subprocess. Remove the bridge when the tooling is retired and saved-settings migration no longer requires it.
- **Unpublished download revision:** The distribution tag is provisional and the UI explains that files are not published. Replace it with an immutable uploaded commit and remove the release-status sentence only when publication is separately authorized.
- **Compiler/dependency diagnostics:** Keep the BNNS warning visible because valid short-input inference passes and restricting inputs would hide the issue. Report the range comparison upstream and rerun compiled checks after compiler updates. Adopt a supported dependency release or a separately reviewed patch for the remaining docstring warning; do not suppress it.

# Notes

Conversion details and commands are in `apps/worker-search/coreml/README.md`. Prepared artifacts, diagnostic variants, and private evaluation data are untracked. Key logs are `/private/tmp/clsp-final-v1-conversion.log`, `/private/tmp/clsp-compiled-check.log`, and `/private/tmp/clsp-compile-range-diagnostic.log`.
