"""Synthetic fixtures for the one-sided review filter."""

import unittest

from review import additions, meeting_additions


class ReviewTests(unittest.TestCase):
    def test_case_punctuation_and_script(self):
        self.assertEqual(
            additions("Hello, WORLD! 後來決定。", "hello world 后来决定"), []
        )

    def test_gpt_omission_does_not_request_review(self):
        self.assertEqual(
            additions(
                "We selected the blue and green options.",
                "We selected the blue option.",
            ),
            ["option"],
        )
        self.assertEqual(
            additions("We selected blue and green.", "We selected blue."), []
        )

    def test_new_fact_and_negation_remain(self):
        self.assertIn(
            "not", additions("Approve the transfer.", "Do not approve the transfer.")[0]
        )
        self.assertTrue(additions("预算五百", "预算五千"))

    def test_changed_order_is_not_automatically_agreement(self):
        self.assertTrue(additions("blue then green", "green then blue"))

    def test_other_apple_track_already_contains_speech(self):
        self.assertEqual(
            meeting_additions(
                ["", "The delivery is Friday."], "The delivery is Friday."
            ),
            [],
        )
        self.assertTrue(
            meeting_additions(
                ["The delivery is Friday.", "Okay."], "The delivery is not Friday."
            )
        )

    def test_empty(self):
        self.assertEqual(additions("Speech here", ""), [])
        self.assertEqual(additions("", "Recovered speech"), ["recovered speech"])


class TriageValidationTests(unittest.TestCase):
    def test_rejects_missing_ids_and_invented_quotes(self):
        from triage import validate

        batch = [{"id": "sample-01", "gpt": "Delivery is Friday."}]
        with self.assertRaises(ValueError):
            validate(batch, [])
        with self.assertRaises(ValueError):
            validate(
                batch,
                [
                    {
                        "id": "sample-01",
                        "decision": "review",
                        "focus_quote": "Monday",
                        "priority": 3,
                    }
                ],
            )

    def test_accepts_verbatim_focus(self):
        from triage import validate

        validate(
            [{"id": "sample-01", "gpt": "Delivery is Friday."}],
            [
                {
                    "id": "sample-01",
                    "decision": "review",
                    "focus_quote": "Friday",
                    "priority": 3,
                }
            ],
        )


if __name__ == "__main__":
    unittest.main()
