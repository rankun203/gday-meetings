"""Synthetic checks for batching, validation, and the original feature split."""
import unittest
import numpy as np
import torch

from redimnet_adapter import EmbeddingFromFeatures, ReDimNetAdapter


class SyntheticModel(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.spec = torch.nn.Identity()
        self.backbone = torch.nn.Identity()
        self.pool = torch.nn.AdaptiveAvgPool1d(1)
        self.bn = torch.nn.Flatten(1)
        self.linear = torch.nn.Linear(1, 2)
        with torch.no_grad():
            self.linear.weight.copy_(torch.tensor([[1.], [2.]]))
            self.linear.bias.copy_(torch.tensor([.3, -.4]))
        self.bn2 = None
        self.before_pool_offset = None
        self.pad_right_samples = None

    def forward(self, waveform):
        return EmbeddingFromFeatures(self)(self.spec(waveform))


class AdapterTests(unittest.TestCase):
    def adapter(self):
        return ReDimNetAdapter(SyntheticModel(), 'cpu', {'embedding_dimension': 2})

    def test_batch_matches_single_without_padding(self):
        adapter = self.adapter()
        audio = np.stack([np.full(600, .1), np.full(600, .4)]).astype('float32')
        batch = adapter.embed_batch(audio)
        np.testing.assert_allclose(np.linalg.norm(batch, axis=1), 1, atol=1e-7)
        for index in range(2):
            np.testing.assert_allclose(batch[index], adapter.embed(audio[index]), atol=1e-7)
        self.assertEqual(batch.dtype, np.float32)

    def test_rejects_wrong_rate_nonfinite_empty_and_short_audio(self):
        adapter = self.adapter()
        for audio in [np.empty((0, 600)), np.zeros((1, 20)), np.full((1, 600), np.nan),
                      np.zeros((1, 1, 600))]:
            with self.subTest(shape=audio.shape), self.assertRaises(ValueError):
                adapter.embed_batch(audio)
        with self.assertRaisesRegex(ValueError, '16 kHz'):
            adapter.embed(np.zeros(600), 8000)

    def test_nonfinite_and_zero_model_outputs_are_rejected(self):
        for value in [float('nan'), 0.]:
            adapter = self.adapter()
            with torch.no_grad():
                adapter.torch_model.linear.weight.fill_(0)
                adapter.torch_model.linear.bias.fill_(value)
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, 'invalid embedding'):
                adapter.embed(np.zeros(600))

    def test_split_preserves_temporal_offset_and_embedding_batchnorm(self):
        model = SyntheticModel()
        model.before_pool_offset = 3
        model.bn2 = torch.nn.BatchNorm1d(2).eval()
        head = EmbeddingFromFeatures(model).eval()
        features = torch.arange(24, dtype=torch.float32).reshape(2, 1, 12)
        with torch.inference_mode():
            expected = model.bn2(model.linear(model.bn(model.pool(features[:, :, 3:]))))
            np.testing.assert_allclose(head(features).numpy(), expected.numpy())


if __name__ == '__main__':
    unittest.main()
