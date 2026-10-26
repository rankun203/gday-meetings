"""Synthetic snapshot safety checks; no production library is read."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location('fixture_prepare', Path(__file__).with_name('prepare.py'))
prepare = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(prepare)


class SnapshotSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.source = self.base / 'source'
        self.folder = self.source / 'meetings/sample'
        self.folder.mkdir(parents=True)
        for name in ('voice-library/examples', 'voice-library/decisions', 'people'):
            (self.source / name).mkdir(parents=True)
        self.metadata = {'id': 'sample-meeting', 'createdAt': 1, 'duration': 20,
                         'audioFiles': ['sample.opus']}
        (self.folder / 'metadata.json').write_text(json.dumps(self.metadata))
        (self.folder / 'sample.opus').write_bytes(b'synthetic-audio')
        (self.source / 'settings.json').write_text('{}')
        self.output = self.base / 'snapshot'

    def test_independent_copy_and_disabled_automation(self):
        result = prepare.snapshot(self.source, self.output, 1)
        self.assertEqual(result['meetings'], 1)
        copied = self.output / 'library/meetings/sample/sample.opus'
        self.assertEqual(copied.read_bytes(), b'synthetic-audio')
        self.assertNotEqual(copied.stat().st_ino, (self.folder / 'sample.opus').stat().st_ino)
        settings = json.loads((self.output / 'library/settings.json').read_text())
        self.assertFalse(settings['automaticVoiceProcessing'])
        self.assertEqual(settings['serviceProviders'], [])

    def test_existing_destination_is_preserved(self):
        self.output.mkdir()
        marker = self.output / 'preserved'
        marker.write_text('keep')
        with self.assertRaises(ValueError):
            prepare.snapshot(self.source, self.output, 1)
        self.assertEqual(marker.read_text(), 'keep')

    def test_pending_root_and_meeting_transactions_are_refused(self):
        for root in (self.source, self.folder):
            with self.subTest(root=root.name):
                journal = root / '.document-transaction'
                journal.mkdir()
                (journal / 'manifest.json').write_text('[]')
                with self.assertRaisesRegex(RuntimeError, 'transaction is pending'):
                    prepare.snapshot(self.source, self.output, 1)
                self.assertFalse(self.output.exists())
                (journal / 'manifest.json').unlink()
                journal.rmdir()

    def test_transaction_appearing_during_capture_is_refused(self):
        original_digest = prepare.digest

        def add_pending_after_copy(path):
            value = original_digest(path)
            if path.is_relative_to(self.output.resolve()):
                (self.source / '.document-transaction').mkdir(exist_ok=True)
            return value

        with mock.patch.object(prepare, 'digest', side_effect=add_pending_after_copy):
            with self.assertRaisesRegex(RuntimeError, 'transaction appeared'):
                prepare.snapshot(self.source, self.output, 1)
        self.assertFalse((self.output / 'manifest.json').exists())

    def test_voice_transaction_is_refused(self):
        (self.source / 'voice-library/transaction.json').write_text('{}')
        with self.assertRaisesRegex(RuntimeError, 'transaction is pending'):
            prepare.snapshot(self.source, self.output, 1)

    def test_unfinished_capture_and_finalization_are_excluded(self):
        for marker, value in [('transcript-checkpoint.json', {'finished': False}),
                              ('recording-finalization-recovery.json', {})]:
            with self.subTest(marker=marker):
                path = self.folder / marker
                path.write_text(json.dumps(value))
                with self.assertRaisesRegex(RuntimeError, 'only 0 completed meetings'):
                    prepare.snapshot(self.source, self.output, 1)
                path.unlink()


if __name__ == '__main__':
    unittest.main()
