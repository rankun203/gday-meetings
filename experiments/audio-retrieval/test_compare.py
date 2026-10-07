"""Synthetic metric checks for incomplete judgments, abstention, and rank fusion."""

import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
from compare import bm25, evidence_metrics, order_scores, relevance_metrics, rrf
from summarize import clustered_interval


class ComparisonTests(unittest.TestCase):
    def test_recall_is_distinct_from_hit(self):
        result = evidence_metrics([0, 1, 2], {0, 2})
        self.assertEqual(result["hit@1"], 1)
        self.assertEqual(result["recall@1"], 0.5)
        self.assertEqual(result["recall@5"], 1)

    def test_zero_lexical_scores_abstain(self):
        scores = bm25(["unmatched", "预算"], ["budget review", "预算调整"])
        order = order_scores(scores, ["doc-b", "doc-a"], lexical=True)
        self.assertEqual(order[0], [])
        self.assertEqual(order[1][0], 1)
        self.assertEqual(evidence_metrics([], {0})["mrr"], 0)

    def test_ties_do_not_depend_on_corpus_order(self):
        ids = ["alpha", "beta", "gamma"]
        first = [ids[i] for i in order_scores(np.ones((1, 3)), ids)[0]]
        ids.reverse()
        second = [ids[i] for i in order_scores(np.ones((1, 3)), ids)[0]]
        self.assertEqual(first, second)

    def test_missing_judgments_are_not_negatives(self):
        with self.assertRaises(ValueError):
            relevance_metrics([0, 1], {0: 3})
        result = relevance_metrics([0], {0: 3, 2: 2})
        self.assertEqual(result["precision@5"], 0.2)
        self.assertLess(result["pooled_ndcg@5"], 1)

    def test_ideal_graded_ranking(self):
        self.assertAlmostEqual(relevance_metrics([0, 1, 2], {0: 3, 1: 2, 2: 0})["pooled_ndcg@5"], 1)

    def test_rrf_does_not_invent_lexical_matches(self):
        values = rrf([[[]], [[2, 1, 0]]], 3)
        self.assertEqual(order_scores(values, ["a", "b", "c"])[0], [2, 1, 0])
        self.assertAlmostEqual(values[0, 2], 1 / 61)

    def test_discussion_match_is_not_answer_support(self):
        result = relevance_metrics([0], {0: 3}, supports={0: "question_only"})
        self.assertEqual(result["direct@1"], 1)
        self.assertEqual(result["full_support@1"], 0)

    def test_dense_fusion_rewards_shared_high_rank_with_equal_weights(self):
        audio = [[0, 1, 2, 3]]
        transcript = [[3, 1, 2, 0]]
        combined = rrf([audio, transcript], 4)
        np.testing.assert_array_equal(combined, rrf([transcript, audio], 4))
        self.assertAlmostEqual(combined[0, 1], 2 / 62)
        self.assertEqual(order_scores(combined, ["a", "b", "c", "d"])[0][0], 1)

    def test_cluster_bootstrap_keeps_queries_together(self):
        result = clustered_interval([1, 1, -1, -1], ["a", "a", "b", "b"], repetitions=1000)
        self.assertEqual(result["difference"], 0)
        self.assertEqual(result["ci95"], [-1, 1])
        self.assertEqual(result["clusters"], 2)

    def test_text_extension_checks_inputs_and_preserves_original_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            dataset, runs, text_run, output = [root / name for name in ["input", "original", "text", "comparison"]]
            for folder in [dataset, runs, text_run]:
                folder.mkdir()
            audio = dataset / "synthetic.wav"
            audio.write_bytes(b"synthetic fingerprint input")
            query = {"query_id": "q1", "query": "delivery schedule", "language": "en", "scenario_id": "s1",
                     "positives": [{"window_id": "d1"}]}
            documents = [{"segment_id": "d1", "transcript_evidence": "delivery schedule", "audio_path": str(audio)},
                         {"segment_id": "d2", "transcript_evidence": "office furniture", "audio_path": str(audio)}]
            (dataset / "queries.jsonl").write_text(json.dumps(query) + "\n")
            (dataset / "corpus.jsonl").write_text("".join(json.dumps(row) + "\n" for row in documents))
            (dataset / "private-manifest.json").write_text(json.dumps({"s1": {"language": "en"}}))
            digest = hashlib.sha256()
            for filename in ["queries.jsonl", "corpus.jsonl"]:
                digest.update((dataset / filename).read_bytes())
            for _ in documents:
                digest.update(audio.read_bytes())
            manifest = text_run / "manifest.json"
            manifest.write_text(json.dumps({"inputs_sha256": digest.hexdigest()}))
            (text_run / "complete.json").write_text(json.dumps({"tasks": 3}))
            for filename, vector in [("query-q1", [1., 0.]), ("transcript-d1", [1., 0.]), ("transcript-d2", [0., 1.])]:
                np.savez(text_run / f"{filename}.npz", embedding=[vector])
            sentinel = runs / "metrics.json"
            sentinel.write_text("original results")
            command = [sys.executable, str(Path(__file__).with_name("compare.py")), str(dataset), str(runs),
                       "--text-run", f"synthetic={text_run}", "--output", str(output)]
            subprocess.run(command, check=True, capture_output=True)
            metrics = json.loads((output / "metrics.json").read_text())
            self.assertEqual(metrics["evidence"]["synthetic"]["all"]["hit@1"], 1)
            self.assertEqual(sentinel.read_text(), "original results")
            manifest.write_text(json.dumps({"inputs_sha256": "different"}))
            failed = subprocess.run(command, capture_output=True, text=True, check=False)
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn("exact inputs", failed.stderr)


if __name__ == "__main__":
    unittest.main()
