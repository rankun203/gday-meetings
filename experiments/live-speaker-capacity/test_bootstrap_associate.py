"""Synthetic causal and trust-boundary checks for temporal correspondence."""

import copy
import unittest

from bootstrap_associate import associate, capacity_safe_baseline, correspondence

POLICY = "nemotron-capacity-rollover-v1"


def fixture(saturated=False):
    old = {
        "source": "microphone",
        "generation": "old",
        "localSpeakerIDs": ["old-label"],
        "publicationStart": 0,
        "observedEnd": 10,
        "policyRevision": POLICY,
    }
    new = {
        "source": "microphone",
        "generation": "new",
        "localSpeakerIDs": ["new-label"],
        "publicationStart": 10,
        "observedEnd": 14,
        "policyRevision": POLICY,
    }
    if saturated:
        new["capacityReachedAt"] = 9
    announcement = dict(new, observedEnd=10)
    entries = []

    def event(window, start, end, intervals):
        entries.append(
            {
                "ordinal": len(entries),
                "audioSubmittedThrough": max(end, 10),
                "kind": "speakerEvent",
                "event": {
                    "source": "microphone",
                    "generation": window["generation"],
                    "start": start,
                    "end": end,
                    "continuity": window,
                    "intervals": intervals,
                },
            }
        )

    event(old, 0, 10, [{"start": 0, "end": 10, "speakerID": "old-label"}])
    event(announcement, 10, 10, [])
    context = {
        "source": "microphone",
        "generation": "new",
        "speakers": [{"id": "new-label"}],
        "start": 4,
        "end": 10,
        "contextOrigin": 4,
        "handoff": 10,
        "policyRevision": POLICY,
        "intervals": [{"start": 4, "end": 10, "speakerID": "new-label"}],
    }
    if saturated:
        context["capacityReachedAt"] = 9
    entries.append(
        {
            "ordinal": len(entries),
            "audioSubmittedThrough": 10,
            "kind": "bootstrapContext",
            "bootstrapContext": context,
        }
    )
    event(new, 10, 14, [{"start": 10, "end": 14, "speakerID": "new-label"}])
    evidence = {
        "windows": [old, new],
        "samples": [],
        "activity": [
            {
                "source": "microphone",
                "localSpeakerID": "old-label",
                "start": 0,
                "end": 10,
            },
            {
                "source": "microphone",
                "localSpeakerID": "new-label",
                "start": 10,
                "end": 14,
            },
        ],
    }
    return evidence, {
        "schemaVersion": 2,
        "contextPolicyRevision": "bootstrap-context-v1-experiment",
        "clock": "submitted-audio-upper-bound",
        "entries": entries,
    }


class BootstrapAssociationTests(unittest.TestCase):
    def test_no_alias_saturated_output_matches_capacity_safe_baseline(self):
        evidence, trace = fixture(True)
        result = associate(evidence, trace)
        actual = [
            dict(row, speaker=row["speaker"].removeprefix("group:"))
            for row in result["finalSnapshot"]
        ]
        self.assertEqual(actual, capacity_safe_baseline(evidence))
        self.assertEqual(sum(r["end"] - r["start"] for r in actual), 14)

    def test_context_namespace_handoff_and_policy_must_match(self):
        for field, value in [
            ("speakers", [{"id": "another"}]),
            ("handoff", 11),
            (
                "policyRevision",
                "nemotron-capacity-credible-runs-300ms-total3s-v2-experiment",
            ),
            ("capacityReachedAt", float("nan")),
        ]:
            evidence, trace = fixture()
            trace["entries"][2]["bootstrapContext"][field] = value
            if field == "handoff":
                trace["entries"][2]["audioSubmittedThrough"] = 11
            with self.assertRaises(ValueError):
                associate(evidence, trace)

    def test_context_chunks_are_monotone_and_capacity_is_sticky(self):
        def split():
            evidence, trace = fixture()
            first = trace["entries"][2]["bootstrapContext"]
            second = copy.deepcopy(first)
            first["end"] = 7
            first["intervals"][0]["end"] = 7
            second["start"] = 7
            second["intervals"][0]["start"] = 7
            trace["entries"].insert(
                3,
                {
                    "ordinal": 3,
                    "audioSubmittedThrough": 10,
                    "kind": "bootstrapContext",
                    "bootstrapContext": second,
                },
            )
            trace["entries"][-1]["ordinal"] = 4
            return evidence, trace

        evidence, trace = split()
        self.assertEqual(
            associate(evidence, trace)["decisions"][0]["admittedAliases"], 1
        )
        for issue in ("overlap", "capacity"):
            evidence, trace = split()
            if issue == "overlap":
                trace["entries"][3]["bootstrapContext"]["start"] = 6
            else:
                trace["entries"][2]["bootstrapContext"]["capacityReachedAt"] = 6
                trace["entries"][3]["bootstrapContext"]["capacityReachedAt"] = 7
            with self.assertRaises(ValueError):
                associate(evidence, trace)

    def test_publication_cannot_change_context_capacity(self):
        evidence, trace = fixture(True)
        trace["entries"][-1]["event"]["continuity"]["capacityReachedAt"] = 8
        with self.assertRaisesRegex(ValueError, "capacity timestamp differs"):
            associate(evidence, trace)

    def test_empty_announcement_waits_for_context_and_first_publication(self):
        evidence, trace = fixture()
        result = associate(evidence, trace)
        self.assertEqual(result["decisions"][0]["callbackOrdinal"], 3)
        self.assertEqual(result["decisions"][0]["admittedAliases"], 1)
        self.assertEqual(len({r["speaker"] for r in result["publishedIntervals"]}), 1)
        self.assertEqual(
            sum(r["end"] - r["start"] for r in result["publishedIntervals"]), 14
        )
        self.assertEqual(len(evidence["activity"]), 2)

    def test_saturated_bootstrap_never_names_continuation(self):
        evidence, trace = fixture(True)
        result = associate(evidence, trace)
        self.assertTrue(result["decisions"][0]["saturatedBootstrapZeroTrust"])
        self.assertEqual(result["aliases"], {})
        self.assertEqual(
            result["publishedIntervals"][-1]["speaker"],
            "unresolved:microphone:new-label",
        )

    def test_old_capacity_cut_prevents_false_overlap_support(self):
        evidence, trace = fixture()
        evidence["windows"][0]["capacityReachedAt"] = 5
        trace["entries"][0]["event"]["continuity"]["capacityReachedAt"] = 5
        result = associate(evidence, trace)
        detail = result["decisions"][0]["candidates"][0]
        self.assertEqual(detail["exclusiveContextSeconds"], 6)
        self.assertEqual(detail["bestMatchedSeconds"], 1)
        self.assertFalse(detail["accepted"])

    def test_future_context_is_rejected(self):
        evidence, trace = fixture()
        late = copy.deepcopy(trace["entries"][2])
        late.update(ordinal=4, audioSubmittedThrough=14)
        trace["entries"].append(late)
        with self.assertRaisesRegex(ValueError, "after first"):
            associate(evidence, trace)

    def test_changed_channel_names_do_not_change_temporal_matching(self):
        evidence, trace = fixture()
        evidence["windows"][1]["localSpeakerIDs"] = ["unrelated-channel"]
        evidence["activity"][1]["localSpeakerID"] = "unrelated-channel"
        for entry in trace["entries"]:
            if entry["kind"] == "bootstrapContext":
                entry["bootstrapContext"]["speakers"] = [{"id": "unrelated-channel"}]
                entry["bootstrapContext"]["intervals"][0]["speakerID"] = (
                    "unrelated-channel"
                )
            elif entry["event"]["generation"] == "new":
                entry["event"]["continuity"]["localSpeakerIDs"] = ["unrelated-channel"]
                for row in entry["event"]["intervals"]:
                    row["speakerID"] = "unrelated-channel"
        result = associate(evidence, trace)
        self.assertEqual(
            result["aliases"],
            {"microphone:unrelated-channel": "group:microphone:old-label"},
        )

    def test_competing_old_labels_reject_weak_agreement(self):
        old = [
            {"source": "microphone", "localSpeakerID": "a", "start": 0, "end": 4},
            {"source": "microphone", "localSpeakerID": "b", "start": 4, "end": 6},
        ]
        context = [
            {"source": "microphone", "localSpeakerID": "new", "start": 0, "end": 6}
        ]
        aliases, details = correspondence(old, context, {})
        self.assertEqual(aliases, {})
        self.assertAlmostEqual(details[0]["agreement"], 2 / 3)

    def test_known_new_overlap_blocks_shared_identity(self):
        old = [{"source": "microphone", "localSpeakerID": "old", "start": 0, "end": 12}]
        context = [
            {"source": "microphone", "localSpeakerID": "a", "start": 0, "end": 7},
            {"source": "microphone", "localSpeakerID": "b", "start": 6, "end": 12},
        ]
        aliases, details = correspondence(old, context, {})
        self.assertEqual(aliases, {})
        self.assertTrue(
            all(
                d["rejection"] == "known_overlapping_new_labels_share_candidate"
                for d in details
            )
        )

    def test_unsupported_trace_or_capacity_policy_is_rejected(self):
        for field in ("schemaVersion", "contextPolicyRevision"):
            evidence, trace = fixture()
            trace[field] = "unsupported"
            with self.assertRaises(ValueError):
                associate(evidence, trace)


if __name__ == "__main__":
    unittest.main()
