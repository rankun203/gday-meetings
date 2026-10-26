"""Synthetic checks for backend comparison and normalization contracts."""
import unittest
import numpy as np
from backend_benchmark import normalized, passes
from coreml_benchmark import parity


class BackendChecks(unittest.TestCase):
    def test_normalization_preserves_direction_and_float32_output(self):
        result = normalized([[3., 4.]])
        self.assertEqual(result.dtype, np.float32)
        np.testing.assert_allclose(result, [[.6, .8]], atol=1e-7)

    def test_invalid_vectors_are_rejected(self):
        for vector in [[0., 0.], [np.nan, 1.], [np.inf, 1.]]:
            with self.subTest(vector=vector), self.assertRaises(ValueError):
                normalized(vector)

    def test_raw_backend_comparison_detects_magnitude_errors(self):
        self.assertFalse(passes(parity([1., 2.], [2., 4.]), .99999, .005))
        self.assertTrue(passes(parity([1., 2.], [1., 2.]), .99999, .005))


if __name__ == '__main__':
    unittest.main()
