import unittest
from replay import observations


class CallbackAdmissionTests(unittest.TestCase):
    def fixture(self):
        sample = dict(id="sample", source="microphone", localSpeakerID="local", start=0, end=3)
        window = dict(source="microphone", generation="window", localSpeakerIDs=["local"],
                      publicationStart=0, observedEnd=3, policyRevision="nemotron-capacity-rollover-v1")
        interval = dict(start=0, end=3, speakerID="local")
        trace = dict(schemaVersion=1, clock="submitted-audio-upper-bound", entries=[
            dict(ordinal=0, kind="embeddingReady", sampleID="sample", audioSubmittedThrough=4),
            dict(ordinal=1, kind="speakerEvent", audioSubmittedThrough=5,
                 event=dict(source="microphone", intervals=[interval], continuity=window))])
        evidence = dict(samples=[sample], activity=[dict(source="microphone", localSpeakerID="local", start=0, end=3)],
                        windows=[window])
        return evidence, trace

    def test_ready_embedding_waits_for_observed_continuity(self):
        evidence, trace = self.fixture()
        row = observations(evidence, trace)[0]
        self.assertEqual(row["embeddingReadyAt"], 4)
        self.assertEqual(row["availableAt"], 5)
        self.assertEqual(row["callbackOrdinal"], 1)

    def test_final_window_does_not_remove_already_admitted_sample(self):
        evidence, trace = self.fixture()
        expected = observations(evidence, trace)
        # A late capacity report concerns earlier acoustic time. It must not
        # retroactively change the decision already made at callback 1.
        final = {**evidence["windows"][0], "observedEnd": 6, "capacityReachedAt": 2}
        evidence["windows"] = [final]
        trace["entries"].append(dict(ordinal=2, kind="speakerEvent", audioSubmittedThrough=6,
                                     event=dict(source="microphone", intervals=[], continuity=final)))
        self.assertEqual(observations(evidence, trace), expected)

    def test_same_admission_callback_preserves_embedding_callback_order(self):
        evidence, trace = self.fixture()
        first = evidence["samples"][0]
        first["id"] = "z-first"
        trace["entries"][0]["sampleID"] = "z-first"
        evidence["samples"].append({**first, "id": "a-second"})
        trace["entries"].insert(1, dict(ordinal=1, kind="embeddingReady", sampleID="a-second", audioSubmittedThrough=4))
        trace["entries"][-1]["ordinal"] = 2
        self.assertEqual([row["sample"]["id"] for row in observations(evidence, trace)], ["z-first", "a-second"])

    def test_ready_before_audio_is_rejected(self):
        evidence, trace = self.fixture()
        trace["entries"][0]["audioSubmittedThrough"] = 2
        with self.assertRaises(ValueError):
            observations(evidence, trace)


if __name__ == "__main__":
    unittest.main()
