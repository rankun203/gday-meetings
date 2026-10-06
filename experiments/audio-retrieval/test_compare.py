"""Synthetic metric checks for incomplete judgments, abstention, and rank fusion."""

import unittest

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

    def test_cluster_bootstrap_keeps_queries_together(self):
        result = clustered_interval([1, 1, -1, -1], ["a", "a", "b", "b"], repetitions=1000)
        self.assertEqual(result["difference"], 0)
        self.assertEqual(result["ci95"], [-1, 1])
        self.assertEqual(result["clusters"], 2)


if __name__ == "__main__":
    unittest.main()
