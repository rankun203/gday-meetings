"""Integrity checks remain active under optimized Python."""

import base64
import io
import json
import subprocess
import sys
import tempfile
import unittest
import wave
from pathlib import Path

from atlas import external_audio
from combine import sha, validate_artifacts, validate_ids, validate_sources
from export import atomic_directory, trust


class IntegrityTests(unittest.TestCase):
    def test_optimized_python_does_not_disable_guards(self):
        code = 'from combine import require; require(False, "expected rejection")'
        result = subprocess.run(
            [sys.executable, "-O", "-c", code],
            cwd=Path(__file__).parent,
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"expected rejection", result.stderr)

    def test_sources_and_namespace_collisions(self):
        source = {"actualSource": "microphone", "id": "one"}
        with self.assertRaises(ValueError):
            validate_sources([source, source])
        evidence = {
            "samples": [{"id": "a", "localSpeakerID": "local"}],
            "activity": [],
            "windows": [{"localSpeakerIDs": ["allocated"]}],
        }
        for seen_samples, seen_labels in [
            ({"a"}, set()),
            (set(), {"allocated"}),
            (set(), {"local"}),
        ]:
            with self.assertRaises(ValueError):
                validate_ids(evidence, seen_samples, seen_labels)
        evidence["samples"].append(evidence["samples"][0])
        with self.assertRaises(ValueError):
            validate_ids(evidence, set(), set())

    def test_required_artifacts_and_hashes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("evidence.json", "receipt.json"):
                (root / name).write_text(json.dumps({}))
            hashes = {
                name: sha(root / name) for name in ("evidence.json", "receipt.json")
            }
            validate_artifacts(root, hashes)
            with self.assertRaises(ValueError):
                validate_artifacts(root, {})
            (root / "evidence.json").write_text("changed")
            with self.assertRaises(ValueError):
                validate_artifacts(root, hashes)

    def test_atomic_failure_removes_partial_export(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "output"

            def fail(staging):
                (staging / "partial").write_text("partial")
                raise ValueError("synthetic failure")

            with self.assertRaises(ValueError):
                atomic_directory(destination, fail)
            self.assertFalse(destination.exists())
            self.assertEqual(list(Path(directory).iterdir()), [])
            atomic_directory(destination, lambda p: (p / "complete").write_text("ok"))
            self.assertTrue((destination / "complete").is_file())
            with self.assertRaises(ValueError):
                atomic_directory(destination, fail)

    def test_external_audio_preserves_bytes_and_requires_loopback(self):
        buffer = io.BytesIO()
        with wave.open(buffer, "wb") as audio:
            audio.setnchannels(1)
            audio.setsampwidth(2)
            audio.setframerate(16000)
            audio.writeframes(b"\x00\x01" * 32)
        data = buffer.getvalue()
        value = "data:audio/wav;base64," + base64.b64encode(data).decode()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            urls, hashes = external_audio(
                [value, value], root, "http://127.0.0.1:8765/projector/audio/"
            )
            self.assertEqual(urls[0], urls[1])
            self.assertEqual(len(hashes), 1)
            name, digest = next(iter(hashes.items()))
            self.assertEqual(name, digest + ".wav")
            self.assertEqual((root / name).read_bytes(), data)
            self.assertEqual(sha(root / name), digest)
            for base in (
                "https://example.invalid/audio/",
                "http://localhost.example.invalid/",
                "http://127.0.0.1@remote.invalid/",
                "file:///tmp/",
            ):
                with self.assertRaises(ValueError):
                    external_audio([value], root, base)

    def test_null_capacity_is_unreached_and_nonfinite_rejected(self):
        sample = {
            "source": "microphone",
            "localSpeakerID": "local",
            "start": 0,
            "end": 3,
        }
        window = {
            "source": "microphone",
            "localSpeakerIDs": ["local"],
            "generation": "one",
            "publicationStart": 0,
            "observedEnd": 4,
            "capacityReachedAt": None,
        }
        self.assertEqual(trust(sample, [window]), ("one", "trusted_window"))
        window["capacityReachedAt"] = float("nan")
        with self.assertRaises(ValueError):
            trust(sample, [window])


if __name__ == "__main__":
    unittest.main()
