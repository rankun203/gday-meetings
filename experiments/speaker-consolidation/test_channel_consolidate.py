"""Synthetic end-to-end checks for the rollover-protected channel-unit experiment."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


@unittest.skipUnless(os.environ.get("CHANNEL_CONSOLIDATE_RUNNER"), "Set CHANNEL_CONSOLIDATE_RUNNER to the compiled executable")
class ChannelConsolidationTests(unittest.TestCase):
    def run_fixture(self, rollover="on", mutate=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            vector = [1.0] + [0.0] * 255
            model = dict(modelID="FluidInference/community1-wespeaker-resnet34",
                         revision="df2625ac79a7ac6b65ad868fee6d80f320da4232",
                         compatibilityVersion="gday-span-feature-center-v2", dimension=256, normalization="unitL2")
            def activity(local, start, end):
                return dict(source="microphone", localSpeakerID=local, start=start, end=end)
            samples = [dict(id=local, **activity(local, start, start+3), embedding=dict(type=model, values=vector), quality=1)
                       for local, start in (("one", 0), ("two", 20), ("overlap", 1))]
            document = dict(samples=samples, activity=[activity("one", 0, 3), activity("one", 100, 103),
                                                       activity("two", 20, 23), activity("overlap", 1, 4),
                                                       activity("no-sample", 110, 113)])
            original = root / "original.json"
            original.write_text(json.dumps(document))
            receipt = root / "receipt.json"
            receipt.write_text(json.dumps(dict(complete=True, gapCount=0, failureCount=0, extractionFailures=0)))
            run = root / "run.json"
            run.write_text(json.dumps(dict(rollover=rollover, returncode=0, artifacts={
                "evidence.json": hashlib.sha256(original.read_bytes()).hexdigest(),
                "receipt.json": hashlib.sha256(receipt.read_bytes()).hexdigest()})))
            if mutate:
                document["activity"][0]["end"] = 4
            corrected = root / "corrected.json"
            corrected.write_text(json.dumps(document))
            result, audit = root / "result.json", root / "audit.json"
            process = subprocess.run([os.environ["CHANNEL_CONSOLIDATE_RUNNER"], str(corrected), str(original),
                                      str(run), str(result), str(audit), "0.7"], capture_output=True, text=True)
            return process, json.loads(result.read_text()) if result.exists() else None, json.loads(audit.read_text()) if audit.exists() else None

    def test_continuity_merge_and_overlap_cannot_link(self):
        process, result, audit = self.run_fixture()
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(len(result["clusters"]), 2)
        assignments = {row["localSpeakerID"]: row.get("clusterID") for row in result["intervals"]}
        self.assertEqual(assignments["one"], assignments["two"])
        self.assertNotEqual(assignments["one"], assignments["overlap"])
        self.assertIsNone(assignments["no-sample"])
        self.assertEqual(audit["channelInferredSpeakerSeconds"], 12)
        self.assertEqual(audit["unresolvedSpeakerSeconds"], 3)
        self.assertEqual(audit["cannotLinkUnitPairs"], 1)

    def test_rejects_unprotected_replay(self):
        process, result, _ = self.run_fixture(rollover="off")
        self.assertNotEqual(process.returncode, 0)
        self.assertIsNone(result)

    def test_rejects_changed_activity(self):
        process, result, _ = self.run_fixture(mutate=True)
        self.assertNotEqual(process.returncode, 0)
        self.assertIsNone(result)


if __name__ == "__main__":
    unittest.main()
