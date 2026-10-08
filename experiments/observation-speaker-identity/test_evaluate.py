import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("observation_evaluate", Path(__file__).with_name("evaluate.py"))
evaluator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evaluator)


class EvaluationTests(unittest.TestCase):
    def test_unresolved_speech_is_not_dropped(self):
        evidence = dict(activity=[dict(source="mic", localSpeakerID="a", start=0, end=5)])
        result = dict(intervals=[dict(source="mic", localSpeakerID="a", start=0, end=5)])
        _, hypothesis = evaluator.intervals(evidence, result)
        self.assertEqual(hypothesis, [dict(start=0, end=5, speaker="unresolved:mic:a")])
        measured = evaluator.score(dict(audioDurationSeconds=5, intervals=[dict(start=0, end=5, speaker="truth")]), hypothesis)
        self.assertEqual(measured["views"][0]["missed_speaker_seconds"], 0)
        self.assertEqual(measured["views"][0]["reference_status"], "saved_worker_annotations_not_ground_truth")

    def test_changed_binary_rejected_before_execution(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runner = root / "runner"
            runner.write_text("changed binary")
            runner.with_suffix(".build.json").write_text(json.dumps(dict(binarySHA256="wrong")))
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps(dict(samples=[])))
            with patch.object(evaluator, "private_output", side_effect=lambda p: p), patch.object(evaluator.subprocess, "run") as execute:
                with self.assertRaisesRegex(ValueError, "Binary does not match"):
                    evaluator.run(manifest, runner, root / "results")
                execute.assert_not_called()

    def test_changed_evidence_rejected_before_execution(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runner = root / "runner"
            runner.write_text("binary")
            runner.with_suffix(".build.json").write_text(json.dumps(dict(binarySHA256=evaluator.sha(runner))))
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps(dict(samples=[dict(id="sample", audioSHA256="audio")])) )
            (root / "sample-on").mkdir()
            (root / "sample-on/evidence.json").write_text("changed evidence")
            (root / "sample-on.run.json").write_text(json.dumps(dict(returncode=0, inputSHA256="audio", artifacts={"evidence.json":"wrong"})))
            with patch.object(evaluator, "private_output", side_effect=lambda p: p), patch.object(evaluator.subprocess, "run") as execute:
                with self.assertRaisesRegex(ValueError, "Frozen input provenance mismatch"):
                    evaluator.run(manifest, runner, root / "results")
                execute.assert_not_called()


if __name__ == "__main__":
    unittest.main()
