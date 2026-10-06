"""Synthetic fixtures for reference provenance and partial review scope."""

import hashlib
import unittest

from apply_review import assemble


class ApplyReviewTests(unittest.TestCase):
    def setUp(self):
        self.annotation = "## sample-01 · review".encode()
        self.queue = [
            {
                "id": "sample-01",
                "meeting": "sample",
                "source": "microphone",
                "start": 0,
                "end": 20,
            }
        ]
        self.decisions = {
            "annotation_sha256": hashlib.sha256(self.annotation).hexdigest(),
            "items": [
                {
                    "id": "sample-01",
                    "spans": [
                        {"text": "green option", "evidence": "audio_review"},
                        {"text": "Pat", "evidence": "context_only"},
                    ],
                }
            ],
        }

    def test_context_identity_excluded_and_span_scope_preserved(self):
        refs, pending = assemble(self.queue, self.decisions, self.annotation)
        self.assertEqual([r["text"] for r in refs], ["green option"])
        self.assertIn("not a complete turn", refs[0]["scope"])
        self.assertEqual(pending, [])

    def test_changed_annotation_rejected(self):
        with self.assertRaisesRegex(ValueError, "hash"):
            assemble(self.queue, self.decisions, self.annotation + b" edited")

    def test_unknown_and_duplicate_ids_rejected(self):
        self.decisions["items"] *= 2
        with self.assertRaisesRegex(ValueError, "duplicate"):
            assemble(self.queue, self.decisions, self.annotation)
        self.decisions["items"][0]["id"] = "missing"
        with self.assertRaisesRegex(ValueError, "Unknown"):
            assemble(self.queue, self.decisions, self.annotation)


if __name__ == "__main__":
    unittest.main()
