"""Synthetic checks for merge/split accounting and unresolved speech."""

import unittest
from score import intervals, purity, score, union_seconds
from evaluate import human_view


def row(start, end, speaker):
    return dict(start=start, end=end, speaker=speaker)


class MetricsTests(unittest.TestCase):
    def test_merge_and_split_are_separate(self):
        ref = [row(0, 2, "a"), row(2, 4, "b")]
        merged = purity(ref, [row(0, 4, "x")])
        self.assertEqual(merged["mergePrecision"], 0.5)
        self.assertEqual(merged["splitRecall"], 1)
        split = purity([row(0, 4, "a")], [row(0, 2, "x"), row(2, 4, "y")])
        self.assertEqual(split["mergePrecision"], 1)
        self.assertEqual(split["splitRecall"], 0.5)

    def test_unreviewed_gaps_do_not_become_silence(self):
        ref = dict(audioDurationSeconds=4, intervals=[row(0, 2, "a")])
        result = score(ref, [row(0, 4, "x")])["views"][0]
        self.assertEqual(result["disagreement_fraction"], 0)
        self.assertEqual(result["hypothesis_speaker_seconds_in_unknown_gaps"], 2)
        ref["reviewedRegions"] = [dict(start=0, end=4)]
        self.assertEqual(score(ref, [row(0, 4, "x")])["views"][0]["disagreement_fraction"], 1)

    def test_unresolved_retains_activity(self):
        activity = dict(source="mic", localSpeakerID="local", start=0, end=2)
        before, after = intervals(dict(activity=[activity]), dict(intervals=[activity]))
        self.assertEqual(union_seconds(before), union_seconds(after))
        self.assertTrue(after[0]["speaker"].startswith("unresolved:"))

    def test_review_mapping_is_shared_across_clips(self):
        clips = [dict(start=start, end=start+2, category="random", intervals=[row(0, 2, "person-a")],
                      reviewedRegions=[dict(start=0, end=2)]) for start in (10, 20)]
        output = human_view(clips, {"candidate": [row(10, 12, "x"), row(20, 22, "y")]}, "random")
        self.assertEqual(output["candidate"]["views"][0]["disagreement_fraction"], 0.5)

    def test_purity_does_not_count_unknown_silence(self):
        output = purity([row(0, 2, "a"), row(2, 4, "b")], [row(0, 4, "x")], [dict(start=0, end=2)])
        self.assertEqual(output["mergePrecision"], 1)
        self.assertEqual(output["pairedExclusiveSeconds"], 2)


if __name__ == "__main__":
    unittest.main()
