"""Synthetic checks for time projection and judgment coverage."""

import unittest

from build import project
from judge import validate


class ExpansionTests(unittest.TestCase):
    def test_words_are_assigned_once_at_boundaries(self):
        segments = [
            {
                "text": "red blue",
                "start": 0,
                "end": 4,
                "words": [
                    {"word": "red", "start": 0, "end": 2},
                    {"word": "blue", "start": 2, "end": 4},
                ],
            }
        ]
        self.assertEqual(project(segments, 0, 2), "red")
        self.assertEqual(project(segments, 2, 4), "blue")
        self.assertEqual(project(segments, 4, 6), "")

    def test_partial_word_alignment_uses_whole_segment(self):
        segments = [
            {
                "text": "one phrase",
                "start": 0,
                "end": 4,
                "words": [{"word": "one", "start": 0, "end": 1}, {"word": "phrase"}],
            }
        ]
        self.assertEqual(project(segments, 0, 2), "")
        self.assertEqual(project(segments, 2, 4), "one phrase")

    def test_chinese_spacing_is_not_an_extra_token_boundary(self):
        self.assertEqual(
            project([{"text": "蓝 色 option", "start": 0, "end": 2}], 0, 3),
            "蓝色 option",
        )

    def test_judgments_must_cover_unique_ids(self):
        batch = [{"review_id": "a"}, {"review_id": "b"}]
        good = [
            {
                "review_id": i,
                "grade": 2,
                "support": "partial",
                "reason": "Only one requested detail appears.",
            }
            for i in ["a", "b"]
        ]
        validate(batch, good)
        with self.assertRaises(ValueError):
            validate(batch, [good[0], good[0]])
        with self.assertRaises(ValueError):
            validate(batch, good[:1])


if __name__ == "__main__":
    unittest.main()
