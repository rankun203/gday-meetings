"""Synthetic checks for benchmark metrics and fixture generation."""
import hashlib
import json
import tempfile
import sys
from types import SimpleNamespace
from unittest.mock import patch
from pathlib import Path
import unittest

import numpy as np

from coreml_benchmark import package_bytes, parity, predict, synthetic_audio, write_json


class CoreMLBenchmarkTests(unittest.TestCase):
    def test_parity_separates_direction_from_scale(self):
        metrics = parity([1., 2.], [2., 4.])
        self.assertAlmostEqual(metrics['cosine'], 1)
        self.assertAlmostEqual(metrics['relative_l2'], 1)

    def test_parity_rejects_invalid_embeddings(self):
        for output in [[0., 0.], [np.nan, 1.], [1.]]:
            with self.subTest(output=output), self.assertRaises(ValueError):
                parity([1., 2.], output)
        with self.assertRaises(ValueError):
            parity([np.nan, 1.], [1., 2.])

    def test_synthetic_audio_is_repeatable_and_exact_length(self):
        waveform = synthetic_audio(2)
        np.testing.assert_array_equal(waveform, synthetic_audio(2))
        self.assertEqual(waveform.shape, (32000,))
        self.assertEqual(waveform.dtype, np.float32)
        self.assertTrue(np.isfinite(waveform).all())

    def test_package_measure_and_atomic_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'weights').write_bytes(b'1234')
            (root / 'nested').mkdir()
            (root / 'nested' / 'model').write_bytes(b'12')
            self.assertEqual(package_bytes(root), 6)
            write_json(root / 'receipt.json', {'status': 'failed'})
            self.assertFalse((root / 'receipt.json.partial').exists())
            self.assertIn('failed', (root / 'receipt.json').read_text())

    def test_runtime_checks_reference_and_checksum_without_torch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = root / 'case.npz'
            np.savez(fixture, features=np.ones((1, 2, 3)), expected=np.array([[1., 2.]]))
            conversion = {'status': 'complete', 'cases': [dict(label='synthetic', package='model.mlpackage',
                          fixture=fixture.name, fixture_sha256=hashlib.sha256(fixture.read_bytes()).hexdigest())]}
            write_json(root / 'conversion.json', conversion)
            args = SimpleNamespace(output=root, fixtures_manifest=None, compute_units='ALL', case_label=None,
                                   repeats=2, minimum_cosine=.999, maximum_relative_l2=.03, receipt=root / 'run.json')
            model = SimpleNamespace(predict=lambda inputs: {'embedding': np.array([[1., 2.]])})
            fake_ct = SimpleNamespace(ComputeUnit=SimpleNamespace(ALL='all'),
                                      models=SimpleNamespace(MLModel=lambda *a, **kw: model))
            fake_psutil = SimpleNamespace(Process=lambda: SimpleNamespace(memory_info=lambda: SimpleNamespace(rss=1024)))
            with patch.dict('sys.modules', {'coremltools': fake_ct, 'psutil': fake_psutil}):
                sys.modules.pop('torch', None)
                result = {}
                predict(args, result)
                self.assertTrue(result['cases'][0]['parity_pass'])
                fixture.write_bytes(b'changed')
                with self.assertRaisesRegex(ValueError, 'checksum'):
                    predict(args, {})

    def test_runtime_guard_rejects_loaded_torch(self):
        with patch.dict('sys.modules', {'torch': SimpleNamespace(), 'coremltools': SimpleNamespace(), 'psutil': SimpleNamespace()}):
            with self.assertRaisesRegex(RuntimeError, 'Torch is loaded'):
                predict(SimpleNamespace(), {})

    def test_runtime_rejects_failed_conversion(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_json(root / 'conversion.json', {'status': 'failed'})
            args = SimpleNamespace(output=root, fixtures_manifest=None)
            with patch.dict('sys.modules', {'coremltools': SimpleNamespace(), 'psutil': SimpleNamespace()}):
                sys.modules.pop('torch', None)
                with self.assertRaisesRegex(ValueError, 'complete'):
                    predict(args, {})


if __name__ == '__main__':
    unittest.main()
