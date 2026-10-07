"""Synthetic ownership checks; no downloaded audio or model is needed."""

import unittest

from score import measure


def row(start, end, speaker):
    return {"start": start, "end": end, "speaker": speaker}


def reference(rows, duration=4):
    return {
        "annotationKind": "source-placement-ownership-not-speech-activity",
        "audioDurationSeconds": duration,
        "intervals": rows,
    }


class OwnershipScoreTests(unittest.TestCase):
    def test_turn_scores_keep_global_mapping(self):
        result = measure(reference([row(0, 3, "a"), row(3, 4, "b")]), [row(0, 4, "x")])
        turns = result["ownershipBreakdown"]["turns"]
        self.assertEqual(turns[0]["metrics"]["conditionalConfusionFraction"], 0)
        self.assertEqual(turns[1]["metrics"]["conditionalConfusionFraction"], 1)
        self.assertEqual(turns[1]["metrics"]["exclusiveCorrectOwnershipFraction"], 0)

    def test_dropped_newcomer_is_visible_after_eighth_arrival(self):
        rows = [row(i, i + 1, str(i)) for i in range(9)]
        result = measure(reference(rows, 9), rows[:8])
        self.assertEqual(result["conditionalConfusionFraction"], 0)
        late = result["ownershipBreakdown"]["strata"]["firstAppearanceAfterEight"]
        self.assertEqual(late["ownershipCoverage"], 0)
        self.assertEqual(late["uncoveredOwnedSeconds"], 1)
        self.assertIsNone(late["conditionalConfusionFraction"])
        self.assertEqual(late["exclusiveCorrectOwnershipFraction"], 0)

    def test_returns_are_separate_from_first_appearances(self):
        rows = [row(0, 1, "a"), row(1, 2, "b"), row(2, 4, "a")]
        result = measure(reference(rows), [row(0, 1, "a"), row(1, 2, "b")])
        breakdown = result["ownershipBreakdown"]
        self.assertEqual(breakdown["strata"]["firstAppearance"]["ownershipCoverage"], 1)
        self.assertEqual(breakdown["strata"]["return"]["ownershipCoverage"], 0)
        self.assertEqual(breakdown["owners"]["a"]["placementCount"], 2)
        self.assertEqual(breakdown["owners"]["a"]["metrics"]["ownedSeconds"], 3)

    def test_permutation_and_duplicate_intervals(self):
        ref = reference([row(0, 2, "a"), row(2, 4, "b")])
        result = measure(ref, [row(0, 2, "y"), row(0, 2, "y"), row(2, 4, "x")])
        self.assertEqual(result["conditionalConfusionFraction"], 0)
        self.assertEqual(result["pairedExclusiveSeconds"], 4)
        self.assertEqual(result["mergePrecision"], 1)
        self.assertEqual(result["splitRecall"], 1)

    def test_merge_and_split_have_distinct_scores(self):
        merged = measure(reference([row(0, 2, "a"), row(2, 4, "b")]), [row(0, 4, "x")])
        self.assertEqual(merged["conditionalConfusionFraction"], 0.5)
        self.assertEqual(merged["mergePrecision"], 0.5)
        self.assertEqual(merged["splitRecall"], 1)
        split = measure(reference([row(0, 4, "a")]), [row(0, 2, "x"), row(2, 4, "y")])
        self.assertEqual(split["mergePrecision"], 1)
        self.assertEqual(split["splitRecall"], 0.5)

    def test_abstention_is_coverage_not_success(self):
        result = measure(reference([row(0, 4, "a")]), [])
        self.assertIsNone(result["conditionalConfusionFraction"])
        self.assertEqual(result["ownershipCoverage"], 0)
        self.assertEqual(result["pairedExclusiveSeconds"], 0)

    def test_injected_silence_and_ambiguous_output(self):
        result = measure(reference([row(0, 2, "a")]), [row(0, 4, "x"), row(0, 1, "y")])
        self.assertEqual(result["activityInInjectedSilenceSeconds"], 2)
        self.assertEqual(result["multipleLabelsOnExclusiveOwnershipSeconds"], 1)
        self.assertEqual(result["pairedExclusiveSeconds"], 1)

    def test_overlap_uses_mapping_fixed_from_exclusive_regions(self):
        ref = reference(
            [row(0, 1, "a"), row(1, 2, "b"), row(2, 4, "a"), row(2, 4, "b")]
        )
        result = measure(ref, [row(0, 1, "x"), row(1, 2, "y"), row(2, 4, "x")])
        self.assertEqual(result["overlapOwnerSetPrecision"], 1)
        self.assertEqual(result["overlapOwnerSetRecall"], 0.5)
        self.assertEqual(result["pairedExclusiveSeconds"], 2)

    def test_invalid_or_untyped_reference_is_rejected(self):
        with self.assertRaises(ValueError):
            measure(reference([row(0, 5, "a")]), [])
        with self.assertRaises(ValueError):
            measure({"audioDurationSeconds": 4, "intervals": []}, [])


if __name__ == "__main__":
    unittest.main()
