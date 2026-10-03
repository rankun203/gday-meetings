import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import transcript_jsonl as migration


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / 'library'
        self.folder = self.root / 'meetings' / 'sample'
        self.folder.mkdir(parents=True)
        self.rows = [{'id': '11111111-1111-1111-1111-111111111111', 'speaker': 'Voice 1',
                      'start': 1.25, 'end': 2.5, 'text': 'Hello\n世界', 'custom': {'retained': True}}]
        self.old = self.folder / 'transcript.json'
        self.old.write_text(json.dumps(self.rows))
        (self.folder / 'audio.opus').write_bytes(b'synthetic audio')

    def apply(self):
        with patch.object(migration, 'require_stopped'):
            return migration.migrate(self.root, self.base / 'backup', migration.plan(self.root))

    def test_roundtrip_preserves_every_other_file_and_backup(self):
        (self.folder / 'transcript-revisions.json').write_text('{"version":1,"revisions":[]}')
        (self.folder / 'live-transcript.json').write_text('{"phrases":[{"text":"alternate"}]}')
        before = migration.inventory(self.root)
        self.assertEqual(self.apply(), 1)
        self.assertEqual(migration.inventory(self.base / 'backup'), before)
        new = self.folder / 'transcript.jsonl'
        self.assertEqual([json.loads(x) for x in new.read_bytes().splitlines()], self.rows)
        self.assertFalse(self.old.exists())
        self.assertEqual(migration.plan(self.root), [])

    def test_conflict_refused(self):
        (self.folder / 'transcript.jsonl').write_text('{}\n')
        with self.assertRaises(migration.MigrationError): migration.plan(self.root)

    def test_empty_snapshot_stays_empty(self):
        self.old.write_text('[]')
        (self.folder / 'live-transcript.json').write_text('{"phrases":[],"effectivePhrases":[]}')
        self.assertEqual(self.apply(), 0)
        self.assertEqual((self.folder / 'transcript.jsonl').read_bytes(), b'')

    def test_empty_current_with_live_text_refused(self):
        self.old.write_text('[]')
        (self.folder / 'live-transcript.json').write_text('{"phrases":[{"text":"saved"}]}')
        with self.assertRaises(migration.MigrationError): migration.plan(self.root)

    def test_live_only_refused(self):
        self.old.unlink()
        (self.folder / 'live-transcript.json').write_text('{}')
        with self.assertRaises(migration.MigrationError): migration.plan(self.root)

    def test_canonical_checkpoint_conflict_refused(self):
        (self.folder / 'transcript-checkpoint.json').write_text('{}')
        with self.assertRaises(migration.MigrationError): migration.plan(self.root)

    def test_embedded_transcript_refused(self):
        self.old.unlink()
        (self.folder / 'content.json').write_text(json.dumps({'transcript': self.rows}))
        with self.assertRaises(migration.MigrationError): migration.plan(self.root)

    def test_invalid_timing_and_identity(self):
        for field, value in [('start', float('nan')), ('end', -1), ('start', True), ('id', 'invalid')]:
            rows = [dict(self.rows[0], **{field: value})]
            with self.assertRaises(migration.MigrationError): migration.rows_from_json(json.dumps(rows))

    def test_symlink_refused(self):
        (self.folder / 'external').symlink_to(self.old)
        with self.assertRaises(migration.MigrationError): self.apply()
        self.assertTrue(self.old.exists())

    def test_running_app_refused(self):
        with patch.object(migration.subprocess, 'check_output', return_value='/Applications/Gday Meetings.app/Contents/MacOS/GdayMeetings\n'):
            with self.assertRaises(migration.MigrationError): migration.require_stopped()

    def test_source_change_after_plan_refused(self):
        changes = migration.plan(self.root)
        self.old.write_text('[]')
        with patch.object(migration, 'require_stopped'):
            with self.assertRaises(migration.MigrationError): migration.migrate(self.root, self.base / 'backup', changes)
        self.assertEqual(self.old.read_text(), '[]')
        self.assertFalse((self.folder / 'transcript.jsonl').exists())

    def test_destination_change_after_plan_refused(self):
        new = self.folder / 'transcript.jsonl'
        new.write_text(json.dumps(self.rows[0]) + '\n')
        changes = migration.plan(self.root)
        changed = dict(self.rows[0], text='Changed after planning')
        new.write_text(json.dumps(changed) + '\n')
        with patch.object(migration, 'require_stopped'):
            with self.assertRaises(migration.MigrationError):
                migration.migrate(self.root, self.base / 'backup', changes)
        self.assertEqual(json.loads(new.read_text()), changed)
        self.assertTrue(self.old.exists())

    def test_existing_backup_refused(self):
        (self.base / 'backup').mkdir()
        with self.assertRaises(migration.MigrationError): self.apply()


if __name__ == '__main__':
    unittest.main()
