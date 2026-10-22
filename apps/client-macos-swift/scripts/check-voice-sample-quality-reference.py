#!/usr/bin/env python3
"""Independent scalar oracle for pcm-signal-v1 synthetic regression fixtures.

Run: uv run --no-project python scripts/check-voice-sample-quality-reference.py
Inputs and thresholds use Float32, including adjacent threshold values. This checks PCM counting only;
it does not evaluate a perceptual quality model or establish model-port parity.
The matching Swift assertions are in VoiceSampleQualityTests.
"""

from array import array
import json
import struct


def float32(value):
    return struct.unpack("f", struct.pack("f", value))[0]


def neighbor(value, steps):
    bits = struct.unpack("I", struct.pack("f", value))[0]
    return struct.unpack("f", struct.pack("I", bits + steps))[0]


silent_threshold = float32(0.00001)
full_scale_threshold = float32(0.999)


def measure(blocks):
    samples = array("f", (value for value, count in blocks for _ in range(count)))
    silent = 0
    full_scale = 0
    for sample in samples:
        if -silent_threshold <= sample <= silent_threshold:
            silent += 1
        if sample <= -full_scale_threshold or sample >= full_scale_threshold:
            full_scale += 1
    return {
        "sampleCount": len(samples),
        "nearSilentFraction": silent / len(samples),
        "fullScaleFraction": full_scale / len(samples),
    }


fixtures = {
    "mixed": ([(0, 16000), (1, 320), (0.25, 15680)], (0.5, 0.01)),
    "silent": ([(0, 32000)], (1.0, 0.0)),
    "bounded_signal": ([(0.25, 32000)], (0.0, 0.0)),
    "negative_full_scale": ([(-1, 32000)], (0.0, 1.0)),
    "silent_boundary": (
        [(neighbor(silent_threshold, -1), 10000), (silent_threshold, 10000), (neighbor(silent_threshold, 1), 12000)],
        (0.625, 0.0),
    ),
    "full_scale_boundary": (
        [(neighbor(full_scale_threshold, -1), 10000), (full_scale_threshold, 10000), (neighbor(full_scale_threshold, 1), 12000)],
        (0.0, 0.6875),
    ),
    "negative_full_scale_boundary": (
        [(-neighbor(full_scale_threshold, -1), 10000), (-full_scale_threshold, 10000), (-neighbor(full_scale_threshold, 1), 12000)],
        (0.0, 0.6875),
    ),
}
for name, (blocks, expected) in fixtures.items():
    result = measure(blocks)
    assert result["sampleCount"] == 32000
    assert (result["nearSilentFraction"], result["fullScaleFraction"]) == expected
    print(json.dumps({"fixture": name, "policy": "pcm-signal-v1", **result}, sort_keys=True))
