"""Synthetic checks for the temporary voice-library migration."""
import json
import tempfile
import unittest
import uuid
from pathlib import Path

from migrate_voice_library import migrate


class MigrationTests(unittest.TestCase):
    def fixture(self):
        vector = {"type": {"modelID": "unknown", "revision": "unknown", "compatibilityVersion": "unknown", "dimension": 2, "normalization": "unknown"}, "values": [1, 0]}
        return {"version": 1, "examples": [{
            "id": str(uuid.uuid4()).upper(), "meetingID": str(uuid.uuid4()),
            "speakerID": str(uuid.uuid4()), "embeddings": [vector], "source": "system",
            "legacyEmbeddings": [vector], "review": "confirmed", "rejectedPersonIDs": [],
            "excluded": False, "manuallyCleared": False, "groupID": str(uuid.uuid4()), "manuallyGrouped": False, "createdAt": 1.0,
        }], "jobs": [], "decisions": [], "undo": [], "deletedPersonIDs": []}

    def test_dry_run_and_verified_backup(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            value = self.fixture()
            original = json.dumps(value).encode()
            source = root / "voice-library.json"
            source.write_bytes(original)
            self.assertFalse(migrate(root)["applied"])
            self.assertEqual(list(root.iterdir()), [source])
            self.assertTrue(migrate(root, apply=True, app_stopped=True)["applied"])
            self.assertEqual((root / "voice-library.json.pre-sharded-backup").read_bytes(), original)
            self.assertFalse(source.exists())
            key = value["examples"][0]["id"]
            metadata = json.loads((root / f"voice-library/examples/{key}.json").read_text())
            vectors = json.loads((root / f"voice-library/representations/{key}.json").read_text())
            self.assertEqual(metadata["embeddings"], [])
            self.assertNotIn("legacyEmbeddings", metadata)
            metadata.update(vectors)
            expected = dict(value["examples"][0])
            expected.pop("legacyEmbeddings")
            self.assertEqual(metadata, expected)
            self.assertEqual((root / "voice-library/state.json").stat().st_mode & 0o777, 0o600)

    def test_invalid_or_duplicate_source_creates_no_destination(self):
        for invalid in [b"invalid", b'{"version": 2}']:
            with tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                source = root / "voice-library.json"
                source.write_bytes(invalid)
                with self.assertRaises((ValueError, KeyError)):
                    migrate(root, apply=True, app_stopped=True)
                self.assertEqual(source.read_bytes(), invalid)
                self.assertEqual(list(root.iterdir()), [source])
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            value = self.fixture()
            value["examples"] *= 2
            source = root / "voice-library.json"
            source.write_text(json.dumps(value))
            with self.assertRaises(ValueError):
                migrate(root, apply=True, app_stopped=True)
            self.assertEqual(list(root.iterdir()), [source])

    def test_existing_guesses_are_preserved_and_people_only_library_is_supported(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            document = self.fixture()
            example = document["examples"][0]
            example["source"] = "unknown"
            example["review"] = "suggested"
            example["suggestedPersonID"] = str(uuid.uuid4())
            (root / "voice-library.json").write_text(json.dumps(document))
            migrate(root, apply=True, app_stopped=True)
            saved = json.loads((root / f"voice-library/examples/{example['id']}.json").read_text())
            self.assertEqual(saved["review"], "suggested")
            self.assertEqual(saved["suggestedPersonID"], example["suggestedPersonID"])
            self.assertNotIn("requiresAudioReview", saved)
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "people").mkdir()
            person = {"id": str(uuid.uuid4()), "voiceSamples": [{"meetingID": str(uuid.uuid4()), "speakerID": str(uuid.uuid4()), "scope": "legacy", "embedding": [1, 0]}]}
            source = root / "people/person.json"
            source.write_text(json.dumps(person))
            before = source.read_bytes()
            migrate(root, apply=True, app_stopped=True)
            self.assertEqual(source.read_bytes(), before)
            self.assertEqual(len(list((root / "voice-library/examples").glob("*.json"))), 1)

    def test_compatible_archived_vectors_join_one_array_without_losing_decisions(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            document = self.fixture()
            example = document["examples"][0]
            example["embeddings"] = []
            example["legacyEmbeddings"] = [{"type": {"modelID": "unknown", "revision": "unknown", "compatibilityVersion": "unknown", "dimension": 256, "normalization": "unknown"}, "values": [3.0] + [0.0] * 255, "provenance": "legacy:rust:runpod"}]
            example["requiresAudioReview"] = True
            example["personID"] = str(uuid.uuid4())
            (root / "voice-library.json").write_text(json.dumps(document))
            migrate(root, apply=True, app_stopped=True)
            key = example["id"]
            saved = json.loads((root / f"voice-library/examples/{key}.json").read_text())
            vectors = json.loads((root / f"voice-library/representations/{key}.json").read_text())
            self.assertEqual(saved["review"], "confirmed")
            self.assertEqual(saved["personID"], example["personID"])
            self.assertNotIn("legacyEmbeddings", vectors)
            self.assertNotIn("requiresAudioReview", saved)
            self.assertEqual(vectors["embeddings"][0]["type"]["normalization"], "unitL2")
            self.assertEqual(vectors["embeddings"][0]["values"][0], 1.0)

    def test_apply_requires_stopped_app_acknowledgment(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "voice-library.json").write_text(json.dumps(self.fixture()))
            with self.assertRaises(ValueError):
                migrate(root, apply=True)
            self.assertFalse((root / "voice-library").exists())


if __name__ == "__main__":
    unittest.main()
