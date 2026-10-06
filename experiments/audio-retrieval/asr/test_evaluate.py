"""Synthetic checks for time projection and script-relative error scoring."""

import unittest

from evaluate import distance, normalize_worker_chinese, project, tokens
from opencc import OpenCC


class EvaluationTests(unittest.TestCase):
    def test_midpoint_has_one_window_owner(self):
        segments = [
            {
                "start": 0,
                "end": 2,
                "text": "first second",
                "words": [
                    {"start": 0, "end": 1, "word": "first"},
                    {"start": 1, "end": 2, "word": "second"},
                ],
            }
        ]
        self.assertEqual(project(segments, 0, 1)[0], "first")
        self.assertEqual(project(segments, 1, 2)[0], "second")

    def test_chinese_word_projection_does_not_insert_character_spaces(self):
        segments = [
            {
                "start": 0,
                "end": 2,
                "text": "星期五",
                "words": [
                    {"start": 0, "end": 1, "text": "星期"},
                    {"start": 1, "end": 2, "text": "五"},
                ],
            }
        ]
        self.assertEqual(project(segments, 0, 2)[0], "星期五")

    def test_missing_timestamps_use_explicit_segment_fallback(self):
        s = [
            {
                "start": 0,
                "end": 2,
                "text": "fifteen dollars",
                "words": [
                    {"word": "fifteen"},
                    {"start": 1, "end": 2, "word": "dollars"},
                ],
            }
        ]
        self.assertEqual(project(s, 0, 2), ("fifteen dollars", 1))

    def test_no_speech_is_empty_not_reference(self):
        self.assertEqual(project([], 0, 1), ("", 0))

    def test_errors_include_deletions_insertions_and_substitutions(self):
        self.assertEqual(distance(["a", "b"], []), 2)
        self.assertEqual(distance(["a"], ["a", "b"]), 1)
        self.assertEqual(distance(["15"], ["50"]), 1)

    def test_normalization_keeps_negation_numbers_and_chinese(self):
        self.assertEqual(tokens("NOT １５，星期五。"), ["not", "15", "星", "期", "五"])

    def test_worker_conversion_reaches_projected_words_without_changing_times(self):
        segments = [
            {
                "start": 0,
                "end": 1,
                "text": "會議",
                "words": [{"start": 0, "end": 1, "word": "會議"}],
            }
        ]
        normalize_worker_chinese(segments, OpenCC("tw2sp"))
        self.assertEqual(segments[0]["text"], "会议")
        self.assertEqual(project(segments, 0, 1), ("会议", 0))
        self.assertEqual(segments[0]["words"][0]["end"], 1)


if __name__ == "__main__":
    unittest.main()
