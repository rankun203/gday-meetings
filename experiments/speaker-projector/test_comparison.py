"""Projection metrics, identities, audio and bounds use synthetic inputs only."""

import base64
import hashlib
import tempfile
import unittest
from pathlib import Path

import numpy as np
from comparison import (
    MAX_SAMPLES,
    aligned_rows,
    atlas_navigation,
    fidelity,
    geometry,
    verify_audio,
)
from scipy.spatial.distance import pdist, squareform


class ComparisonTests(unittest.TestCase):
    def test_scaled_rotated_projection_preserves_distances(self):
        points = np.array([[0.0, 0], [1, 0], [0, 2], [3, 4]])
        distances = squareform(pdist(points))
        projected = (points @ np.array([[0, -1], [1, 0]])) * 7 + 30
        metric = fidelity(distances, projected)
        self.assertEqual(metric["pairCount"], 6)
        self.assertAlmostEqual(metric["spearman"], 1)
        self.assertAlmostEqual(metric["scaledStress"], 0)
        self.assertAlmostEqual(metric["scale"], 1 / 7)
        bad = fidelity(distances, points[[0, 2, 1, 3]])
        self.assertGreater(bad["scaledStress"], 0.1)

    def test_degenerate_metrics_explicitly_undefined(self):
        result = fidelity(np.zeros((3, 3)), np.zeros((3, 2)))
        self.assertIsNone(result["spearman"])
        self.assertIsNone(result["scaledStress"])
        self.assertEqual(result["pairCount"], 3)

    def test_row_mapping_joins_by_identity_not_viewer_order(self):
        canonical = []
        for i in range(3):
            canonical.append(
                {
                    "id": str(i),
                    "sampleID": str(i),
                    "start": i,
                    "end": i + 1,
                    "source": "microphone",
                    "cluster": "cluster-a",
                    "role": "replay_sample",
                    "trustReason": "trusted_window",
                    "representativeRank": None,
                    "reviewConfirmedPerson": None,
                }
            )
        viewer = [
            {
                **r,
                "source_id": r["source"],
                "cluster_id": r["cluster"],
                "Cluster": "Cluster 01",
                "audio": "http://localhost/audio/" + r["id"],
            }
            for r in canonical
        ]
        rows = aligned_rows(canonical, viewer[::-1])
        self.assertEqual([r["row"] for r in rows], [0, 1, 2])
        self.assertEqual([r["id"] for r in rows], ["0", "1", "2"])
        viewer[0]["sampleID"] = "wrong"
        with self.assertRaises(ValueError):
            aligned_rows(canonical, viewer)

    def test_audio_swap_or_remote_url_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            site = Path(directory)
            (site / "projector/audio").mkdir(parents=True)
            data = b"synthetic audio bytes"
            digest = hashlib.sha256(data).hexdigest()
            name = digest + ".wav"
            (site / "projector/audio" / name).write_bytes(data)
            canonical = {
                "audio": "data:audio/wav;base64," + base64.b64encode(data).decode()
            }
            receipt = {
                "audioBaseURL": "http://localhost/audio/",
                "audioSHA256": {name: digest},
            }
            row = {"audio": receipt["audioBaseURL"] + name}
            verify_audio(canonical, row, receipt, site)
            for url in (
                "https://example.invalid/" + name,
                "http://localhost/audio/wrong.wav",
            ):
                with self.assertRaises(ValueError):
                    verify_audio(canonical, {"audio": url}, receipt, site)
            canonical["audio"] = (
                "data:audio/wav;base64,"
                + base64.b64encode(b"different sample").decode()
            )
            with self.assertRaises(ValueError):
                verify_audio(canonical, row, receipt, site)

    def test_bounds_and_identical_embeddings_rejected(self):
        for values in (
            np.zeros((3, 256)),
            np.ones((3, 256)),
            np.ones((MAX_SAMPLES + 1, 256)),
            np.ones((2, 256)),
        ):
            with self.assertRaises(ValueError):
                geometry(values, np.zeros((len(values), 2)))

    def test_metric_mds_and_exact_cosine_preserve_sample_order(self):
        vectors = np.zeros((4, 256))
        vectors[0, 0] = 1
        vectors[1, 1] = 1
        vectors[2, 0] = -1
        vectors[3, 1] = -1
        xy = np.array([[1, 0], [0, 1], [-1, 0], [0, -1]])
        cosine, mds, metrics = geometry(vectors, xy)
        self.assertEqual(cosine[0, 2], -1)
        self.assertEqual(cosine[0, 1], 0)
        self.assertTrue(np.allclose(np.diag(cosine), 1))
        self.assertLess(metrics["mds"]["scaledStress"], 0.01)
        self.assertAlmostEqual(metrics["umap"]["scaledStress"], 0)
        self.assertEqual(mds.shape, (4, 2))

    def test_atlas_navigation_reserves_height_without_bundle_changes(self):
        html = '<html><head></head><body><div id="app"></div></body></html>'
        updated = atlas_navigation(html)
        self.assertIn("grid-template-rows:44px", updated)
        self.assertIn("calc(100dvh - 44px)", updated)
        self.assertIn("../comparison.html", updated)
        self.assertEqual(atlas_navigation(updated), updated)


if __name__ == "__main__":
    unittest.main()
