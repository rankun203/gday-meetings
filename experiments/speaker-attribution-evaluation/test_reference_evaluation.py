"""Synthetic leakage, ranking, provenance and selection regression checks."""

import copy
import dataclasses
import json
import tempfile
import unittest
from pathlib import Path

import numpy as np
from reference_evaluation import (
    Example,
    classify,
    evaluate,
    evaluate_acoustic_reports,
    evaluate_negatives,
    evaluate_unknown,
    load_examples,
    normalized,
    replay_profile,
    score_profile,
    select_profile,
    summarize,
)


def example(
    identifier,
    person="person-a",
    meeting="meeting-a",
    vector=(1.0, 0.0),
    duration=3.0,
    created=0.0,
    quality=1.0,
):
    return Example(
        identifier,
        person,
        meeting,
        "model-v1",
        tuple(normalized(vector)),
        created,
        duration,
        "confirmed_without_selection_receipt",
        "synthetic",
        quality,
        identifier,
    )


class ReferenceEvaluationTests(unittest.TestCase):
    def test_whole_query_meeting_is_excluded_from_every_profile(self):
        samples = [
            example("a1"),
            example("a2", meeting="meeting-b", vector=(0.8, 0.2)),
            example("b1", person="person-b", vector=(1.0, 0.0)),
        ]
        _, details = evaluate(
            samples,
            caps=(3,),
            scorers=("maximum",),
            selections=("diverse_batch",),
            repeats=1,
        )
        held_out = next(row for row in details if row["query"] == "a1")
        self.assertEqual(held_out["winner"], "person-a")
        self.assertEqual([person for person, score in held_out["ranked"]], ["person-a"])
        without_own = next(row for row in details if row["query"] == "b1")
        self.assertFalse(without_own["supported"])

    def test_person_holdout_removes_every_reference_of_the_true_person(self):
        samples = [
            example("a1"),
            example("a2", meeting="meeting-b"),
            example("b1", person="person-b", meeting="meeting-c", vector=(0.9, 0.1)),
        ]
        summaries, details = evaluate_unknown(samples, caps=(1,), scorers=("maximum",))
        self.assertEqual(summaries[0]["queries"], 3)
        self.assertTrue(all(row["winner"] != row["held_out_person"] for row in details))
        self.assertEqual(summaries[0]["false_accepts"], 3)

    def test_selector_uses_duration_and_stable_ties(self):
        self.assertEqual(
            select_profile([example("b"), example("a")], 1)[0].identifier, "a"
        )
        short = example("a", duration=0.3)
        long = example("b", duration=3.0)
        self.assertEqual(select_profile([short, long], 1), [long])
        self.assertEqual(select_profile([long], 24), [long])
        self.assertEqual(select_profile([long], 0), [])
        with self.assertRaises(ValueError):
            select_profile([long, example("c", person="person-b")], 2)

    def test_diversity_retains_different_directions(self):
        samples = [
            example("a"),
            example("b", vector=(0.99, 0.01)),
            example("c", vector=(0.0, 1.0)),
        ]
        selected = select_profile(samples, 2)
        self.assertIn("c", [e.identifier for e in selected])

    def test_aggregation_uses_distinct_math(self):
        query = example("query")
        refs = [example("a"), example("b", vector=(0.0, 1.0))]
        self.assertAlmostEqual(score_profile(query, refs, "maximum"), 1.0)
        self.assertAlmostEqual(score_profile(query, refs, "mean"), 0.5)
        self.assertAlmostEqual(score_profile(query, refs, "top3_mean"), 0.5)
        self.assertAlmostEqual(score_profile(query, refs, "centroid"), 2**-0.5)

    def test_tentative_requires_real_competitor_and_margin(self):
        query = example("query", vector=(0.6, 0.8))
        self.assertEqual(
            classify(query, {"person-a": [example("a")]}, "maximum")["tier"],
            "abstained",
        )
        two = {
            "person-a": [example("a")],
            "person-b": [example("b", person="person-b", vector=(-1.0, 0.0))],
        }
        self.assertEqual(classify(query, two, "maximum")["tier"], "tentative")
        tied = {
            "person-a": [example("a")],
            "person-b": [example("b", person="person-b")],
        }
        self.assertEqual(classify(query, tied, "maximum")["tier"], "abstained")

    def test_replay_stop_and_replacement_are_different_bounded_policies(self):
        first = example("a", duration=0.1, created=1.0)
        newer = example("b", vector=(0.0, 1.0), duration=3.0, created=2.0)
        self.assertEqual(replay_profile([newer, first], 1, False), [first])
        self.assertEqual(replay_profile([newer, first], 1, True), [newer])

    def test_pairwise_rejection_has_no_invented_alternate_truth(self):
        negative = dataclasses.replace(
            example("negative", person=None), rejected=("person-b",)
        )
        references = [example("b", person="person-b", meeting="meeting-b")]
        result = evaluate_negatives([negative], references)
        self.assertEqual(result["usable_pairs"], 1)
        self.assertEqual(result["above_automatic_floor"], 1)
        self.assertNotIn("truth", result["pairs"][0])

    def test_missing_own_profile_is_reported_separately(self):
        metrics = summarize(
            [
                {"truth": "a", "winner": "b", "supported": False, "tier": "tentative"},
                {"truth": "a", "winner": "a", "supported": True, "tier": "automatic"},
            ]
        )
        self.assertEqual(metrics["queries_without_own_profile"], 1)
        self.assertEqual(metrics["wrong_assigned"], 1)
        self.assertEqual(metrics["correct_coverage"], 0.5)

    def test_loader_excludes_conflicting_audio_and_preserves_provenance(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            records = root / "voice-library" / "examples"
            records.mkdir(parents=True)
            values = [
                {
                    "id": "a",
                    "personID": "person-a",
                    "meetingID": "meeting-a",
                    "source": "system",
                    "audioFile": "system.wav",
                    "audioRevision": "v1",
                    "start": 0,
                    "end": 3,
                    "review": "confirmed",
                    "embeddings": [{"type": {"model": "synthetic"}, "values": [1, 0]}],
                },
                {
                    "id": "b",
                    "personID": "person-b",
                    "meetingID": "meeting-a",
                    "source": "system",
                    "audioFile": "system.wav",
                    "audioRevision": "v1",
                    "start": 0,
                    "end": 3,
                    "review": "confirmed",
                    "embeddings": [{"type": {"model": "synthetic"}, "values": [0, 1]}],
                },
                {
                    "id": "c",
                    "personID": "person-a",
                    "meetingID": "meeting-c",
                    "source": "system",
                    "audioFile": "system.wav",
                    "audioRevision": "v2",
                    "start": 0,
                    "end": 3,
                    "review": "confirmed",
                    "selectedReference": {"policy": "synthetic"},
                    "sampleQuality": {
                        "policy": "pcm-signal-v1",
                        "audioRevision": "stale-v1",
                        "nearSilentFraction": 1.0,
                        "range": {
                            "audioFile": "system.wav",
                            "source": "system",
                            "start": 0,
                            "end": 3,
                        },
                    },
                    "embeddings": [{"type": {"model": "synthetic"}, "values": [1, 1]}],
                },
            ]
            for value in values:
                (records / (value["id"] + ".json")).write_text(json.dumps(value))
            loaded, _negatives, audit = load_examples(root)
            self.assertEqual([e.identifier for e in loaded], ["c"])
            self.assertEqual(loaded[0].provenance, "selected_after_manual_identity")
            self.assertEqual(
                loaded[0].quality, 1.0, "Stale PCM ratings remain unassessed"
            )
            self.assertEqual(audit["counts"]["conflicting_exact_audio_records"], 2)

    def test_quality_receipts_require_complete_current_binding(self):
        receipt = {
            "policy": "pcm-signal-v1",
            "audioRevision": "v1",
            "scanConfiguration": "configuration-v1",
            "sampleCount": 48000,
            "nearSilentFraction": 1.0,
            "fullScaleFraction": 0.0,
            "range": {
                "audioFile": "system.wav",
                "source": "system",
                "start": 0,
                "end": 3,
            },
        }
        changes = [
            {},
            {"policy": "old"},
            {"audioRevision": "old"},
            {"scanConfiguration": ""},
            {"sampleCount": 1},
            {"nearSilentFraction": float("nan")},
            {"nearSilentFraction": 1.1},
            {"fullScaleFraction": float("inf")},
            {"range": {**receipt["range"], "end": 4}},
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            records = root / "voice-library" / "examples"
            records.mkdir(parents=True)
            for index, changed in enumerate(changes):
                quality = {**copy.deepcopy(receipt), **changed}
                value = {
                    "id": "sample",
                    "personID": "person-a",
                    "meetingID": "meeting-a",
                    "source": "system",
                    "audioFile": "system.wav",
                    "audioRevision": "v1",
                    "start": 0,
                    "end": 3,
                    "review": "confirmed",
                    "sampleQuality": quality,
                    "embeddings": [{"type": {"model": "synthetic"}, "values": [1, 0]}],
                }
                (records / "sample.json").write_text(json.dumps(value))
                loaded, _, _ = load_examples(root)
                self.assertEqual(loaded[0].quality, 0.0 if index == 0 else 1.0)

    def test_sparse_acoustic_accuracy_keeps_repeated_passes_separate(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            resource = {"wall": 1.0, "cpu": 1.0, "peakRSSBytes": 1000}
            run = {
                "index": 0,
                "assignments": [
                    {
                        "track": "track-a",
                        "start": 0.0,
                        "end": 2.0,
                        "personID": "person-a",
                    }
                ],
                "scan": resource,
                "incremental": resource,
                "total": resource,
                "additionalExtractorCalls": 1,
                "baselineExtractorCalls": 1,
                "clusters": [],
            }
            path.write_text(
                json.dumps(
                    {
                        "mode": "synthetic",
                        "sourceRevision": "test",
                        "modelRevision": "test",
                        "runs": [run, {**run, "index": 1}],
                    }
                )
            )
            report = evaluate_acoustic_reports(
                [path], [{"track": "track-a", "at": 1.0, "personID": "person-a"}]
            )
            self.assertEqual(report["known_annotation_points"], 1)
            self.assertEqual(
                [p["correct"] for p in report["methods"][0]["accuracy_passes"]], [1, 1]
            )

    def test_invalid_vectors_are_rejected(self):
        for vector in ([], [0, 0], [float("nan"), 1], [float("inf")]):
            with self.assertRaises(ValueError):
                normalized(vector)
        np.testing.assert_allclose(normalized([1e300, 1e300]), [2**-0.5, 2**-0.5])


if __name__ == "__main__":
    unittest.main()
