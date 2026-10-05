---
title: Native CLSP preprocessing
date: 2026-10-06
status: validated
scope: swift-clsp-preprocessing
---

## Problem

The CLSP provider required an external Python worker. Native inference needs matching text tokens and audio features; a different mel frontend or resampler can change the embedding space.

## Implemented solution

The native loader reads a bounded source-rate range using AVAudioFile or libopusfile, averages channels, and resamples once. The existing libopusfile bridge accepts only single-link mono/stereo Opus and rejects multichannel/chained streams; other native formats average every decoded channel, up to the explicit 32-channel bound. A Swift port of torchaudio 2.8's Hann-windowed sinc resampling uses width 6, rolloff 0.99, zero padding, and ceiling output length. Compact filter support avoids quadratic memory for unusual sample-rate ratios.

The frontend implements CLSP's Kaldi filterbank contract: 16 kHz mono PCM without amplitude scaling, 400-sample Povey window, 160-sample step, endpoint-duplicating reflection, per-frame DC subtraction and 0.97 preemphasis, 512-point Accelerate FFT, 128 triangular mel bins from 20 to 7,600 Hz, power spectrum, Float32 epsilon clamp, and natural log. There is no dithering or column normalization. The unused energy-floor option does not change spectral log clamping.

RoBERTa tokenization uses the maintained Hugging Face Swift Tokenizers package pinned to 1.3.4. Assets load from the verified local model folder. Single text sequences retain BOS/EOS, truncate to 512 tokens, and expose Int32 IDs and masks. No Python runtime or inference-time network request is introduced.

## Reasoning

FluidAudio's native NeMo frontend has different framing and normalization, and its Kaldi Core ML asset has a fixed contract. Reusing either would not establish CLSP parity. The Swift port follows [torchaudio's Kaldi source](https://github.com/pytorch/audio/blob/v2.8.0/src/torchaudio/compliance/kaldi.py) and [resampling source](https://github.com/pytorch/audio/blob/v2.8.0/src/torchaudio/functional/functional.py). Tokenization uses [Hugging Face Swift Transformers](https://github.com/huggingface/swift-transformers/tree/1.3.4) rather than a separate BPE implementation.

## Validation

Synthetic golden fixtures are generated with pinned torch 2.8.0, torchaudio 2.8.0, and transformers 4.57.3. They cover silence, impulses at boundaries, mixed signals, 8/22.05/44.1/48 kHz conversion, CJK and emoji text, special tokens, whitespace, and truncation. `scripts/generate-clsp-preprocessing-fixtures.py` takes a local tokenizer directory; it does not download weights. The tokenizer integration test is explicitly enabled with `GDAY_CLSP_TOKENIZER_DIRECTORY`; DSP fixtures run without model files. The preprocessing and worker lifecycle suites passed nine focused tests with the full local tokenizer test enabled. Compilation confirmed the earlier redundant `#require` warning was removed. Sixteen text fixtures matched Python token IDs exactly, including 512-token truncation and literal special tokens. The native WAV fixture verified a bounded range and arithmetic averaging of every channel in a three-channel file, plus invalid and too-short range errors.

Resampler maximum absolute errors were 8.94e-8 at 8 kHz, 1.19e-7 at 22.05 kHz, 1.49e-7 at 44.1 kHz, and 1.04e-7 at 48 kHz, within the 1e-5 test bound. Filterbank silence was exact; impulse error was 4.77e-6; mixed-signal maximum error was 2.289e-4 natural-log units with RMS 1.977e-5. The worst bin's reference power was 1.616e-7, near Float32 epsilon. This corresponds to about 0.023% relative power. An independent Python comparison using a Float64 FFT rounded to Float32 also differed from the Float32 FFT by 1.993e-4 log units. The accepted stage bounds are maximum 5e-4 and RMS 5e-5, reflecting numerical FFT rounding rather than different preprocessing. The separate model evaluation reported all 150 prepared 16 kHz clips above 0.99999994 cosine. Ten original Opus ranges initially fell as low as 0.99892 against Python SoundFile decoding. Using the same libopusfile decoder, native resampled PCM matched sample counts exactly, with maximum absolute error 2.384e-7, maximum RMS error 1.452e-8, and minimum cosine 0.999999999999915. The corresponding model embeddings reached minimum cosine 0.999999996 and maximum component error 2.72e-7. This establishes the decoder boundary rather than hiding it in a relaxed model tolerance. Retrieval ranking and the full conversion report remain separate evaluation outputs; no retrieval-quality claim is made here.

The first tokenizer check caught duplicated BOS/EOS: the RoBERTa postprocessor already supplies these tokens. The wrapper now keeps its processed IDs and preserves EOS when truncating. The first multichannel fixture needed an explicit native three-channel layout; its corrected run passed. Logs are under ignored temporary storage; no user audio or text is part of these fixtures.

## Worker lifecycle review

The Core ML worker serializes prediction off the main actor. Preparation is shared by concurrent requests and identified so an older failed waiter cannot clear a newer retry. Cancelled callers preserve the shared lease; shutdown callers join the same preparation and release operation. Requests validate text and audio bounds before loading models, and prediction results reject invalid dimensions, nonfinite values, and zero norms.

After 30 seconds without active requests, the worker drops prepared models and releases its lease. New requests cancel the idle timer or wait for a release already underway before preparing again. Preparation and prediction count as active work. Shutdown cancels the timer and joins any release. A final resource owner also schedules idempotent lease release when deallocated, covering providers dropped without explicit shutdown. Explicit shutdown still awaits cleanup. A synthetic ownership test drops a leased worker with a one-hour idle timeout and verifies release without waiting for that timer. This allows model removal and bounds memory retention without adding settings. Synthetic tests cover delayed preparation, overlapping shutdown, cancelled callers, preparation failure and retry, invalid requests and vectors, and idle release followed by reuse.

The production provider constructs the native worker; no production controller constructs the Python client. The opt-in native evaluation harness releases its worker on success and failure and checks that the model lease count returns to zero. Its full model and retrieval evaluation remains the parent conversion task's responsibility.

The first full-suite run under concurrent model conversion exceeded the lifecycle fixtures' five-second preparation-start polling deadline. The fixture now uses a buffered asynchronous start signal with cancellation and a one-minute test limit; idle-release waiting uses that same test cancellation bound. This changes test scheduling only. The revised lifecycle fixtures, including automatic cleanup when a worker is dropped, passed in the 987-test full-suite run without compiler warnings. The full run failed only the existing live-transcript final-phrase test: its real five-second provider deadline expired while concurrent tests occupied the main actor. Production and the test remain unchanged; validation now runs that timing-sensitive test separately from the rest of the suite.

An opt-in decoder-only diagnostic in CLSPNativeEvaluationTests exports explicitly supplied original audio ranges as local Float32 arrays. It does not load models or print private audio paths. The original-file comparison needs to distinguish native libopusfile decoding from the Python SoundFile decoder before attributing differences to the resampler or model.

## Technical debt

The pinned third-party tokenizer is reused rather than duplicating BPE. Tokenizer integration tests require the explicitly supplied local asset directory and are skipped without it; DSP and decoder tests remain self-contained. Keep the golden generator and model/tokenizer revision together when upgrading. Native Opus decoding differs from the Python SoundFile path on the measured original ranges. The native embedding-space revision must remain distinct so old representations are not silently reused. Preserve decoder parity fixtures and version the space again if the decoding contract changes.

Final validation: the suite excluding the single deadline-sensitive test passed all 987 tests in 33.404 seconds, with the packaged tokenizer assets enabled and no compiler warnings. Global Swift formatting checks passed. The unchanged deadline-sensitive test passed separately in 0.532 seconds. Release build and UI validation belong to the parent integration task.

A release UI check found the first model settings view still displaying Preparing after the preparation receipt had been written. Reopening the provider showed Ready immediately, and a subsequent voice query completed normally. A focused synthetic regression confirmed both the state publisher and object-change publisher deliver Preparing → Ready (passed in 0.008 seconds without compiler warnings). This narrows the remaining UI investigation to view observation or lifecycle behavior; no timer or manual notification was added. The parent integration task owns repeat UI validation before release approval.
