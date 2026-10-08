---
title: Preserve capture continuity across sample-rate conversion
date: 2026-10-08
status: focused validation passed
scope: microphone and system audio recording and live delivery
---

# Capture resampler continuity

## Problem

A device route can change its sample rate while the recorded track keeps its original format. The writer previously compared the next input timestamp with the number of converted frames already written. A stateful resampler temporarily withholds output while accumulating filter context. The writer treated that delay as a capture outage, inserted silence, and reset the converter. Every following callback then paid the same initial delay again.

A synthetic reproduction supplied twenty contiguous 100 ms buffers at 48 kHz to a 24 kHz track. The original writer delivered only 1.7 seconds of the two seconds to live consumers, creating nineteen artificial 15 ms discontinuities. Those discontinuities can reset live speaker labeling repeatedly, allocate unused identities, and add processing and UI work. The reproduction uses no microphone gain control or speech detector.

## Implemented solution

The fix tracks accepted input time independently of emitted output frames. Continuous callbacks advance the input clock even when conversion produces no output yet. Overlapping input is discarded or trimmed before entering the converter so duplicate audio cannot contaminate its retained state.

At a genuine outage, format transition, or finalization, the writer drains delayed converted audio up to the accepted input boundary. It discards filter output beyond that boundary and bounds drain work by the number of accepted but unwritten frames. Explicit outage padding advances the accepted boundary so late callbacks cannot overwrite it.

Muting discards pending audible converter state and resolves its remaining timeline as intentional silence. No retained pre-mute audio may reach live consumers after muting. Automatic microphone gain control and voice-processing settings are unchanged.

## Reasoning

Increasing the gap tolerance would hide real outages and leave periodic missing samples in the recording. Separating the input and output clocks addresses the cause while retaining existing host-time alignment and genuine-gap handling. Draining at conversion boundaries preserves the final portion of accepted audio rather than replacing it with silence.

## Validation

The final focused run passed 27 tests across four suites in 3.849 seconds, including the previously failing reproduction, existing writer tests, and new continuity tests. New cases cover continuous downsampling, small buffers that initially produce no output, format transitions, duplicate and partial-overlap rejection, real outages, and mute followed immediately by finalization. Seven sample-rate and packet-size combinations include genuinely fractional output lengths and both upsampling and downsampling. The promoted source matches the tested copies byte for byte. Full integrated release validation remains pending.

These tests use synthetic audio and disposable files. No existing meeting audio is rewritten. The fix changes future recording and live delivery; it cannot reconstruct audio already discarded during an earlier recording.

## Technical debt

None. The full integrated app and release checks remain required before completing the broader feature.
