"""Check guarded instrumentation without touching a model runtime or live checkout."""

import json
from pathlib import Path
import tempfile
import unittest

from install_bootstrap_context import ADAPTER, COLLECTOR, ROOT, adapter_patch, collector_patch, install, sha


class BootstrapContextInstallerTests(unittest.TestCase):
    def fixture(self, package):
        original = ROOT / "apps/client-macos-swift"
        for name in (ADAPTER, COLLECTOR, "Sources/GdayMeetings/Core/LiveSpeakerCapacity.swift",
                     "Sources/GdayMeetings/Core/SpeakerEvidence.swift"):
            target = package / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((original / name).read_bytes())

    def test_install_preserves_inputs_and_records_exact_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory)
            self.fixture(package)
            before = {name: (package / name).read_bytes() for name in (ADAPTER, COLLECTOR)}
            receipt = install(package)
            for name, data in before.items():
                self.assertEqual((package / "bootstrap-context-before" / name).read_bytes(), data)
                self.assertEqual(receipt["beforeSHA256"][name], sha(data))
                self.assertEqual(receipt["afterSHA256"][name], sha((package / name).read_bytes()))
            self.assertEqual(receipt["availabilitySchemaVersion"], 2)
            self.assertEqual(receipt["contextPolicyRevision"], "bootstrap-context-v1-experiment")
            self.assertEqual(json.loads((package / "bootstrap-context-install.json").read_text()), receipt)
            for name, digest in receipt["unchangedSourceSHA256"].items():
                self.assertEqual(sha((package / "Sources/GdayMeetings/Core" / name).read_bytes()), digest)
            with self.assertRaises(ValueError):
                install(package)

    def test_rejects_changed_baseline_and_symlink_escape(self):
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory) / "package"
            self.fixture(package)
            target = package / ADAPTER
            original = target.read_bytes()
            target.write_bytes(original + b"\n// Changed fixture\n")
            with self.assertRaises(ValueError):
                install(package)
            target.unlink()
            outside = Path(directory) / "outside.swift"
            outside.write_bytes(original)
            target.symlink_to(outside)
            with self.assertRaises(ValueError):
                install(package)
            self.assertEqual(outside.read_bytes(), original)
            self.assertFalse((package / "bootstrap-context-install.json").exists())

    def test_instrumentation_keeps_sample_gate_and_published_collector_intact(self):
        original = ROOT / "apps/client-macos-swift"
        adapter = (original / ADAPTER).read_text()
        collector = (original / COLLECTOR).read_text()
        changed = adapter_patch(adapter)
        # Sample selection and publication clipping must not be rewritten by this probe.
        sample_start = "                if let slot = clean {"
        sample_end = "            session.emitted += result.frameCount"
        self.assertEqual(adapter.split(sample_start)[1].split(sample_end)[0],
                         changed.split(sample_start)[1].split(sample_end)[0])
        publication_start = "    nonisolated static func publication("
        self.assertEqual(adapter.split(publication_start)[1], changed.split(publication_start)[1])
        modified_collector = collector_patch(collector)
        published_start = "    func receive(_ event: LiveSpeakerEvent) {"
        published_end = "    func receive(_ sample: LiveSpeakerAudioSample,"
        self.assertEqual(collector.split(published_start)[1].split(published_end)[0],
                         modified_collector.split(published_start)[1].split(published_end)[0])
        with self.assertRaises(ValueError):
            adapter_patch(changed)


if __name__ == "__main__":
    unittest.main()
