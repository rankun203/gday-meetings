"""Synthetic mapping and compatibility checks; no private meeting fixtures."""

import copy
import unittest

from export import (
    VERSION,
    build_rows,
    covered_seconds,
    neighbors_and_diagnostics,
    vector,
)


def sample(identifier, start=0, label="local-a", direction=0):
    values = [0.0] * 256
    values[direction] = 1.0
    return {
        "id": identifier,
        "source": "microphone",
        "localSpeakerID": label,
        "start": start,
        "end": start + 3,
        "embedding": {"type": {"compatibilityVersion": VERSION}, "values": values},
    }


def fixture():
    evidence = {
        "samples": [sample("live")],
        "windows": [
            {
                "source": "microphone",
                "generation": "window-a",
                "localSpeakerIDs": ["local-a"],
                "publicationStart": 0,
                "observedEnd": 20,
            }
        ],
        "activity": [],
    }
    result = {
        "clusters": [
            {
                "id": "cluster-a",
                "sampleIDs": ["live"],
                "representativeSampleIDs": ["live"],
            }
        ],
        "rejectedSampleIDs": [],
        "intervals": [],
    }
    historical = {
        "people": {
            "person-a": {"name": "Alex", "email": "never-export@example.invalid"}
        },
        "speakers": [{"id": "old-label", "label": "Speaker A", "personID": "person-a"}],
        "examples": [
            {
                "id": "ref",
                "source": "microphone",
                "start": 6,
                "end": 9,
                "review": "confirmed",
                "personID": "person-a",
            }
        ],
    }
    return evidence, result, historical


class ExportTests(unittest.TestCase):
    def test_context_never_assigns_replay_person(self):
        evidence, result, historical = fixture()
        rows = build_rows(
            evidence,
            result,
            historical,
            {"samples": [sample("ref", 6)]},
            [{"source": "microphone", "start": 0, "end": 3, "speakerID": "old-label"}],
        )
        self.assertIn("Alex", rows[0]["historicalContext"])
        self.assertIsNone(rows[0]["reviewConfirmedPerson"])
        self.assertEqual(rows[1]["reviewConfirmedPerson"], "Alex")
        self.assertEqual(rows[0]["representativeRank"], 1)
        self.assertNotIn("never-export", str(rows))
        neighbors_and_diagnostics(rows)
        self.assertEqual(rows[0]["diagnosticReferenceCosine"], 1)
        self.assertEqual(rows[0]["neighbors"]["ids"], [1])
        self.assertEqual(rows[0]["neighbors"]["distances"], [0])

    def test_unconfirmed_channel_name_not_reference_identity(self):
        evidence, result, historical = fixture()
        historical["examples"][0]["review"] = "unassigned"
        rows = build_rows(
            evidence, result, historical, {"samples": [sample("ref", 6)]}, []
        )
        neighbors_and_diagnostics(rows)
        self.assertIsNone(rows[1]["reviewConfirmedPerson"])
        self.assertIsNone(rows[0]["diagnosticReferenceName"])

    def test_overlap_excluded_from_named_reference_diagnostics(self):
        evidence, result, historical = fixture()
        historical["examples"][0].update(start=1, end=4)
        rows = build_rows(
            evidence, result, historical, {"samples": [sample("ref", 1)]}, []
        )
        neighbors_and_diagnostics(rows)
        self.assertIsNone(rows[0]["diagnosticReferenceName"])
        self.assertEqual(rows[0]["overlappingReferencesExcluded"], 1)

    def test_incompatible_and_malformed_vectors_rejected(self):
        for change in ("v1", "dimension", "nan"):
            value = sample("sample")
            if change == "v1":
                value["embedding"]["type"]["compatibilityVersion"] = "v1"
            elif change == "dimension":
                value["embedding"]["values"] = [1]
            else:
                value["embedding"]["values"][0] = float("nan")
            with self.assertRaises(ValueError):
                vector(value)

    def test_cluster_and_reference_mapping_integrity(self):
        evidence, result, historical = fixture()
        for mutation in ("duplicate", "missing", "representative"):
            altered = copy.deepcopy(result)
            if mutation == "duplicate":
                altered["clusters"].append(altered["clusters"][0])
            elif mutation == "missing":
                altered["clusters"] = []
            else:
                altered["clusters"][0]["representativeSampleIDs"] = ["unknown"]
            with self.assertRaises(ValueError):
                build_rows(evidence, altered, historical, {}, [])
        with self.assertRaises(ValueError):
            build_rows(
                evidence, result, historical, {"samples": [sample("ref", 7)]}, []
            )

    def test_untrusted_saturated_sample_remains_in_export(self):
        evidence, result, historical = fixture()
        evidence["samples"].append(sample("saturated", 4))
        evidence["windows"][0]["capacityReachedAt"] = 3
        rows = build_rows(evidence, result, historical, {}, [], ["saturated"])
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[1]["productionSampleStatus"], "untrusted")
        self.assertEqual(rows[1]["trustReason"], "after_capacity")
        self.assertIsNone(rows[1]["cluster"])
        self.assertFalse(rows[1]["trusted"])
        with self.assertRaises(ValueError):
            build_rows(evidence, result, historical, {}, [], ["saturated", "live"])

    def test_capacity_and_union_coverage(self):
        evidence, result, historical = fixture()
        evidence["windows"][0]["capacityReachedAt"] = 2
        rows = build_rows(evidence, result, historical, {}, [])
        self.assertEqual(rows[0]["trustReason"], "after_capacity")
        self.assertFalse(rows[0]["trusted"])
        self.assertEqual(covered_seconds([sample("a"), sample("b", 1)]), 4)


if __name__ == "__main__":
    unittest.main()
