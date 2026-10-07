"""Synthetic invariants for the causal association experiment."""

import copy
import json
import tempfile
import unittest
from pathlib import Path

from online_associate import (
    associate,
    availability_times,
    selected_samples,
    sha,
    verified_replay,
)


def fixture():
    windows = [
        {
            "source": "microphone",
            "generation": str(i),
            "localSpeakerIDs": [label],
            "publicationStart": start,
            "observedEnd": end,
            "policyRevision": "nemotron-capacity-rollover-v1",
        }
        for i, (label, start, end) in enumerate([("a", 0, 10), ("b", 10, 20)])
    ]

    def sample(label, start, end, values):
        return {
            "id": label + str(end),
            "source": "microphone",
            "localSpeakerID": label,
            "start": start,
            "end": end,
            "embedding": {
                "values": values,
                "type": {"compatibilityVersion": "gday-span-feature-center-v2"},
            },
        }

    return {
        "windows": windows,
        "activity": [
            {
                "source": "microphone",
                "localSpeakerID": label,
                "start": start,
                "end": end,
            }
            for label, start, end in [("a", 0, 10), ("b", 10, 20)]
        ],
        "samples": [sample("a", 1, 4, [1.0, 0.0]), sample("b", 11, 14, [1.0, 0.0])],
    }


class OnlineAssociationTests(unittest.TestCase):
    def test_supported_experimental_policy_is_explicit(self):
        e = fixture()
        for window in e["windows"]:
            window["policyRevision"] = (
                "nemotron-capacity-credible-runs-300ms-total3s-v2-experiment"
            )
        self.assertEqual(associate(e)["trustedSamples"], 2)
        e["windows"][0]["policyRevision"] = "unknown-policy"
        with self.assertRaises(ValueError):
            associate(e)

    def test_replay_loader_rejects_failed_incomplete_and_tampered_receipts(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp) / "synthetic-on"
            folder.mkdir()
            sample = {
                "id": "synthetic",
                "audioSHA256": "input-hash",
                "durationSeconds": 20,
            }
            (folder / "evidence.json").write_text(json.dumps(fixture()))
            base = {
                "complete": True,
                "failureCount": 0,
                "gapCount": 0,
                "extractionFailures": 0,
                "sampleCount": 2,
                "durationSeconds": 20,
            }

            def write_receipt(value, status="completed"):
                (folder / "receipt.json").write_text(json.dumps(value))
                run = {
                    "status": status,
                    "returncode": 0,
                    "sample": "synthetic",
                    "rollover": "on",
                    "inputSHA256": "input-hash",
                    "artifacts": {
                        name: sha(folder / name)
                        for name in ["evidence.json", "receipt.json"]
                    },
                }
                folder.with_suffix(".run.json").write_text(json.dumps(run))

            write_receipt(base)
            self.assertEqual(len(verified_replay(folder, sample)[0]["samples"]), 2)
            for field in ["failureCount", "gapCount", "extractionFailures"]:
                write_receipt(dict(base, **{field: 1}))
                with self.assertRaises(ValueError):
                    verified_replay(folder, sample)
            write_receipt(dict(base, complete=False))
            with self.assertRaises(ValueError):
                verified_replay(folder, sample)
            write_receipt(base, status="interrupted")
            with self.assertRaises(ValueError):
                verified_replay(folder, sample)
            write_receipt(base)
            (folder / "evidence.json").write_text("{}")
            with self.assertRaises(ValueError):
                verified_replay(folder, sample)

    def test_unknown_or_empty_selection_rejected(self):
        manifest = {"samples": [{"id": "synthetic"}]}
        for selection in [[], ["missing"]]:
            with self.assertRaises(ValueError):
                selected_samples(manifest, selection)

    def test_saturated_alias_cannot_reclaim_untrusted_activity(self):
        e = fixture()
        e["windows"][1]["capacityReachedAt"] = 17
        result = associate(e, delay=0, policy="sticky")
        for field in ("intervals", "finalSnapshot"):
            self.assertTrue(
                all(
                    r["speaker"] == "unresolved:microphone:b"
                    for r in result[field]
                    if r["start"] >= 17
                )
            )
            self.assertTrue(
                any(
                    r["speaker"] == "microphone:a" and r["start"] >= 14
                    for r in result[field]
                )
            )

    def test_sticky_association_survives_later_mean_drift(self):
        e = fixture()
        for index in range(4):
            future = copy.deepcopy(e["samples"][-1])
            future.update(id=f"later-{index}", start=15 + index, end=16 + index)
            future["embedding"]["values"] = [0.0, 1.0]
            e["samples"].append(future)
        result = associate(e, delay=0, policy="sticky")
        self.assertEqual(result["events"][-1]["person"], "microphone:a")
        self.assertEqual(sum(event["changed"] for event in result["events"]), 1)

    def test_known_overlap_prevents_two_current_labels_matching_one_person(self):
        e = fixture()
        e["windows"][1]["localSpeakerIDs"].append("c")
        e["activity"].append(
            {"source": "microphone", "localSpeakerID": "c", "start": 12, "end": 20}
        )
        sample = copy.deepcopy(e["samples"][-1])
        sample.update(id="c", localSpeakerID="c", start=14, end=17)
        e["samples"].append(sample)
        result = associate(e, policy="sticky")
        self.assertEqual(result["events"][-1]["person"], "microphone:c")

    def trace_fixture(self, late=False):
        e = fixture()
        entries = []

        def ready(index, time):
            entries.append(
                {
                    "ordinal": len(entries),
                    "audioSubmittedThrough": time,
                    "kind": "embeddingReady",
                    "sampleID": e["samples"][index]["id"],
                }
            )

        def publish(index, time):
            row = e["activity"][index]
            entries.append(
                {
                    "ordinal": len(entries),
                    "audioSubmittedThrough": time,
                    "kind": "speakerEvent",
                    "event": {
                        "source": "microphone",
                        "continuity": e["windows"][index],
                        "intervals": [
                            {
                                "speakerID": row["localSpeakerID"],
                                "start": row["start"],
                                "end": row["end"],
                            }
                        ],
                    },
                }
            )

        ready(0, 4)
        publish(0, 10)
        if late:
            publish(1, 20)
            ready(1, 25)
        else:
            ready(1, 14)
            publish(1, 20)
        return e, {
            "schemaVersion": 1,
            "clock": "submitted-audio-upper-bound",
            "entries": entries,
        }

    def test_trace_waits_for_observed_continuity(self):
        e, trace = self.trace_fixture()
        ready = availability_times(e, trace)
        self.assertEqual(ready[e["samples"][0]["id"]][:2], (10, 1))
        self.assertEqual(ready[e["samples"][1]["id"]][:2], (20, 3))
        result = associate(e, delay=0, policy="sticky", trace=trace)
        checkpoint = result["snapshots"][0]
        self.assertEqual(checkpoint["time"], 20)
        self.assertEqual(
            {r["speaker"] for r in checkpoint["before"]},
            {"microphone:a", "microphone:b"},
        )
        self.assertEqual({r["speaker"] for r in checkpoint["after"]}, {"microphone:a"})
        self.assertEqual(
            {r["speaker"] for r in result["publishedIntervals"]},
            {"microphone:a", "microphone:b"},
        )

    def test_finish_callback_after_audio_affects_final_snapshot(self):
        e, trace = self.trace_fixture(late=True)
        result = associate(e, delay=0, policy="sticky", trace=trace)
        self.assertEqual(result["events"][-1]["time"], 25)
        self.assertEqual(
            {r["speaker"] for r in result["finalSnapshot"]}, {"microphone:a"}
        )

    def test_trace_must_reconstruct_activity(self):
        e, trace = self.trace_fixture()
        trace["entries"][-1]["event"]["intervals"] = []
        with self.assertRaises(ValueError):
            associate(e, trace=trace)

    def test_availability_and_no_retroactive_updates(self):
        result = associate(fixture(), delay=1)
        second = [r for r in result["intervals"] if r["start"] >= 10]
        self.assertEqual(
            second,
            [
                {"start": 10, "end": 15, "speaker": "microphone:b"},
                {"start": 15, "end": 20, "speaker": "microphone:a"},
            ],
        )

    def test_future_vectors_do_not_change_prefix(self):
        e = fixture()
        future = copy.deepcopy(e["samples"][-1])
        future.update(id="later", start=16, end=19)
        future["embedding"]["values"] = [0.0, 1.0]
        before = associate(e)
        e["samples"].append(future)
        after = associate(e)
        self.assertEqual(before["events"], after["events"][:2])
        self.assertEqual(
            [r for r in before["intervals"] if r["end"] <= 15],
            [r for r in after["intervals"] if r["end"] <= 15],
        )

    def test_saturated_samples_do_not_enter_profile(self):
        e = fixture()
        e["windows"][1]["capacityReachedAt"] = 13
        result = associate(e)
        self.assertEqual(result["rejectedSamples"], 1)
        self.assertTrue(
            all(
                r["speaker"]
                == ("microphone:b" if r["end"] <= 13 else "unresolved:microphone:b")
                for r in result["intervals"]
                if r["start"] >= 10
            )
        )

    def test_full_activity_duration_retained(self):
        e = fixture()
        e["samples"] = []
        result = associate(e)
        self.assertEqual(sum(r["end"] - r["start"] for r in result["intervals"]), 20)
        self.assertEqual(
            {r["speaker"] for r in result["intervals"]},
            {"microphone:a", "microphone:b"},
        )

    def test_same_window_channels_remain_distinct(self):
        e = fixture()
        e["windows"][0]["localSpeakerIDs"].append("b")
        e["windows"][0]["observedEnd"] = 20
        e["windows"].pop()
        self.assertFalse(any(event["changed"] for event in associate(e)["events"]))

    def test_invalid_delay_and_incompatible_samples_rejected(self):
        with self.assertRaises(ValueError):
            associate(fixture(), delay=-1)
        e = fixture()
        e["samples"][1]["embedding"]["type"]["compatibilityVersion"] = "old"
        with self.assertRaises(ValueError):
            associate(e)


if __name__ == "__main__":
    unittest.main()
