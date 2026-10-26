"""Synthetic frontend and embedding-contract checks; no checkpoints required."""

import unittest
from pathlib import Path
import tempfile
import types
from unittest.mock import Mock, patch

import numpy as np
import torch
import torchaudio.compliance.kaldi as kaldi

from eres_cam_adapter import Adapter, CAM, ERES


class AdapterTests(unittest.TestCase):
    def adapter(self, identity):
        adapter = Adapter.__new__(Adapter)
        adapter.model_id = identity
        adapter.device = torch.device('cpu')
        adapter.torch_model = lambda features: features.std(dim=1)[:, :4]
        return adapter

    def test_frontends_match_official_inference(self):
        wave = np.random.default_rng(4).normal(0, .02, 32000).astype('float32')
        for identity in (ERES, CAM):
            adapter = self.adapter(identity)
            tensor = torch.from_numpy(wave).unsqueeze(0)
            args = dict(num_mel_bins=80, sample_frequency=16000, dither=0)
            if identity == CAM:
                tensor = tensor * 32768
                args.update(frame_length=25, frame_shift=10, window_type='hamming', use_energy=False)
            expected = kaldi.fbank(tensor, **args)
            expected -= expected.mean(0, keepdim=True)
            torch.testing.assert_close(adapter.features(wave)[0], expected)
            torch.testing.assert_close(adapter.features(tensor / (32768 if identity == CAM else 1))[0], expected)

    def test_batch_matches_individual_without_padding(self):
        adapter = self.adapter(CAM)
        waves = np.random.default_rng(7).normal(0, .02, (2, 8000)).astype('float32')
        batch = adapter.embed_batch(waves)
        np.testing.assert_allclose(batch, np.stack([adapter.embed(w) for w in waves]), atol=1e-6)
        np.testing.assert_allclose(np.linalg.norm(batch, axis=1), 1, atol=1e-6)

    def test_checkpoint_and_backend_metadata(self):
        for identity, checkpoint_name, dimension, package in [
                (ERES, 'pretrained_eres2netv2w24s4ep4.ckpt', 192, 'speakerlab'),
                (CAM, 'avg_model.pt', 512, 'wespeaker')]:
            with self.subTest(identity=identity), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / checkpoint_name).write_bytes(b'synthetic checkpoint')
                parameter = torch.zeros(1)
                model = Mock()
                model.eval.return_value = model
                model.to.return_value = model
                model.parameters.side_effect = lambda: iter([parameter])
                architecture = types.SimpleNamespace(ERes2NetV2=lambda **kwargs: model,
                                                     CAMPPlus=lambda **kwargs: model)
                namespace = types.ModuleType(package)
                namespace.__path__ = [str(root / package)]
                with patch.dict('sys.modules', {package: namespace}), \
                     patch('eres_cam_adapter.torch.load', return_value={}), \
                     patch('eres_cam_adapter.subprocess.run', return_value=types.SimpleNamespace(stdout='0' * 40)), \
                     patch('eres_cam_adapter.importlib.import_module', return_value=architecture):
                    adapter = Adapter(identity, root, root)
                self.assertEqual(adapter.metadata['checkpoint'], checkpoint_name)
                self.assertEqual(adapter.metadata['embedding_dimension'], dimension)
                self.assertEqual(adapter.metadata['dtype'], 'torch.float32')
                self.assertEqual(adapter.metadata['backend'], 'cpu')
                self.assertEqual(adapter.metadata['frontend_device'], 'cpu')
                self.assertEqual(adapter.metadata['torch_version'], str(torch.__version__))
                self.assertTrue(adapter.metadata['torchaudio_version'])

    def test_invalid_input_and_outputs(self):
        adapter = self.adapter(ERES)
        for wave in (np.zeros(20), np.full(500, np.nan), np.zeros((2, 500))):
            with self.assertRaises(ValueError):
                adapter.features(wave)
        with self.assertRaises(ValueError):
            adapter.embed_batch(np.zeros(500))
        adapter.torch_model = lambda features: torch.zeros((features.shape[0], 4))
        with self.assertRaises(ValueError):
            adapter.embed(np.zeros(8000, dtype='float32'))


if __name__ == '__main__':
    unittest.main()
