"""Synthetic production-policy checks without loading Core ML models."""

import unittest

import numpy as np

from wespeaker_coreml_adapter import (
    Adapter, active_frame_count, centered_features, duration_weights, validate_waveform,
)


class FakeModel:
    def __init__(self, predict):
        self.predict = predict


class PolicyTests(unittest.TestCase):
    def test_center_uses_real_frames_and_zeros_padding(self):
        features = np.full((1, 1, 80, 998), 1000, dtype=np.float32)
        active = active_frame_count(32000)
        self.assertEqual(active, 198)
        features[..., :active] = np.arange(active)
        centered = centered_features(features, 32000)
        np.testing.assert_array_equal(centered[..., active:], 0)
        np.testing.assert_allclose(centered[..., :active].mean(axis=-1), 0, atol=1e-6)
        self.assertEqual(centered.dtype, np.float32)
        self.assertEqual(active_frame_count(160000), 998)

    def test_duration_mask_preserves_independent_rounding(self):
        for samples, count in [(32000, 118), (80000, 295), (160000, 589)]:
            mask = duration_weights(samples)
            np.testing.assert_array_equal(mask[0, :count], 1)
            np.testing.assert_array_equal(mask[0, count:], 0)
        self.assertEqual(duration_weights(80000).sum(), 295)

    def test_input_and_feature_validation(self):
        for wave in [np.zeros(31999), np.zeros(160001), np.zeros((1, 32000)), np.full(32000, np.nan)]:
            with self.assertRaises(ValueError):
                validate_waveform(wave)
        for features in [np.zeros((80, 998)), np.full((1, 1, 80, 998), np.inf)]:
            with self.assertRaises(ValueError):
                centered_features(features, 32000)

    def test_prediction_contract_padding_mask_and_normalization(self):
        adapter = Adapter.__new__(Adapter)
        calls = []

        def fbank(inputs):
            calls.append(inputs)
            return {'fbank_features': np.ones((1, 1, 80, 998), dtype=np.float32)}

        def embedding(inputs):
            calls.append(inputs)
            return {'embedding': np.ones((1, 256), dtype=np.float32)}

        adapter.fbank = FakeModel(fbank)
        adapter.embedding = FakeModel(embedding)
        wave = np.full(32000, .25, dtype=np.float32)
        result = adapter.embed(wave)
        np.testing.assert_array_equal(calls[0]['audio'][0, 0, :32000], wave)
        np.testing.assert_array_equal(calls[0]['audio'][0, 0, 32000:], 0)
        np.testing.assert_array_equal(calls[1]['fbank_features'], 0)
        self.assertEqual(calls[1]['weights'].sum(), 118)
        np.testing.assert_array_equal(result, np.full(256, 1 / 16))
        self.assertEqual(adapter.embed_batch(np.stack([wave, wave])).shape, (2, 256))
        adapter.embedding = FakeModel(lambda _: {'embedding': np.zeros((1, 256))})
        with self.assertRaises(ValueError):
            adapter.embed(wave)
        with self.assertRaises(ValueError):
            adapter.embed_batch(wave)


if __name__ == '__main__':
    unittest.main()
