"""Synthetic stopped-app migration checks; never access a real library."""

import importlib.util
import json
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "pack_search", Path(__file__).parents[1] / "pack-search-artifacts.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.library, self.backup = root / "library", root / "backup"
        self.source = (
            self.library
            / "meetings/fixture/providers/local-search/space/embeddings.json"
        )
        self.source.parent.mkdir(parents=True)
        self.original = json.dumps(
            {
                "space": "fixture",
                "meetingID": "00000000-0000-0000-0000-000000000001",
                "revision": "one",
                "windows": [
                    {
                        "id": "one",
                        "text": "Synthetic",
                        "kind": "notes",
                        "people": [],
                        "vector": [0.8, 0.6] + [0.0] * 382,
                    }
                ],
            }
        ).encode()
        self.source.write_bytes(self.original)

    def run_migration(self, *flags, processes=""):
        with (
            patch(
                "sys.argv",
                [
                    "pack",
                    "--library",
                    str(self.library),
                    "--backup",
                    str(self.backup),
                    *flags,
                ],
            ),
            patch.object(MODULE.subprocess, "check_output", return_value=processes),
        ):
            MODULE.main()

    def test_dry_run_preserves_source(self):
        self.run_migration()
        self.assertEqual(self.source.read_bytes(), self.original)
        self.assertFalse(self.source.with_name("embeddings.packed").exists())

    def test_apply_and_resume_preserve_backup_and_packed_precisions(self):
        saved = self.backup / self.source.relative_to(self.library)
        saved.parent.mkdir(parents=True)
        saved.write_bytes(self.original)  # Interrupted run after its backup.
        self.run_migration("--apply")
        self.assertFalse(self.source.exists())
        self.assertEqual(saved.read_bytes(), self.original)
        packed = plistlib.loads(self.source.with_name("embeddings.packed").read_bytes())
        self.assertEqual(len(packed["fp32"]), 1536)
        self.assertEqual(len(packed["int8"]), 384)
        self.run_migration("--apply")

    def test_active_app_blocks_migration(self):
        with self.assertRaises(SystemExit):
            self.run_migration(
                "--apply",
                processes="/Applications/Fixture.app/Contents/MacOS/GdayMeetings\n",
            )
        self.assertEqual(self.source.read_bytes(), self.original)

    def test_isolated_preview_does_not_block_real_library_migration(self):
        executable = (
            Path(self.temporary.name) / "Preview.app/Contents/MacOS/GdayMeetings"
        )
        executable.parent.mkdir(parents=True)
        (executable.parent.parent / "Info.plist").write_bytes(
            plistlib.dumps({"GdayUIPreview": True})
        )
        self.run_migration("--apply", processes=str(executable) + "\n")
        self.assertFalse(self.source.exists())

    def test_explicit_temporary_copy_allows_live_app(self):
        self.run_migration(
            "--apply",
            "--isolated-copy",
            processes="/Applications/Fixture.app/Contents/MacOS/GdayMeetings\n",
        )
        self.assertFalse(self.source.exists())

    def test_different_target_and_bad_norm_are_rejected(self):
        self.source.with_name("embeddings.packed").write_bytes(b"different")
        with self.assertRaises(ValueError):
            self.run_migration("--apply")
        self.assertEqual(self.source.read_bytes(), self.original)
        artifact = json.loads(self.original)
        artifact["windows"][0]["vector"] = [0.0] * 384
        with self.assertRaises(ValueError):
            MODULE.pack(json.dumps(artifact))


if __name__ == "__main__":
    unittest.main()
