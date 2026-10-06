"""Check complete grading coverage and the denominator for missing results."""

import unittest

from score_variants import summarize_support


class SupportTests(unittest.TestCase):
    def test_empty_result_counts_as_zero(self):
        pool = {"r1": {}}
        key = [
            {
                "review_id": "r1",
                "condition": "sample",
                "method": "encoder",
                "query_id": "q1",
            }
        ]
        judgments = [
            {
                "review_id": "r1",
                "grade": 3,
                "support": "full",
                "reason": "States the requested value.",
            }
        ]
        result = summarize_support(pool, key, judgments, 2)["sample"]["encoder"]
        self.assertEqual(result["useful@1"], 0.5)
        self.assertEqual(result["full_support@1"], 0.5)
        self.assertEqual(result["returned"], 1)

    def test_incomplete_or_duplicate_grading_is_rejected(self):
        judgment = {
            "review_id": "r1",
            "grade": 3,
            "support": "full",
            "reason": "Direct evidence.",
        }
        for rows in [[], [judgment, judgment]]:
            with self.assertRaises(ValueError):
                summarize_support({"r1": {}}, [], rows, 2)


if __name__ == "__main__":
    unittest.main()
