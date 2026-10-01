from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from score_review import score
from private_paths import private_output


class GoldTests(unittest.TestCase):
    def test_local_can_beat_reference(self):
        gold = dict(status='reviewed', selection='independent', audioDurationSeconds=4,
                    reviewedRegions=[dict(start=0, end=4)],
                    intervals=[dict(start=1, end=2, speaker='person')])
        result = score(gold, {'server': [dict(start=0, end=3, speaker='a')],
                             'local': [dict(start=1, end=2, speaker='b')]})
        self.assertEqual(result['systems']['server'][0]['diarization_error_rate'], 2)
        self.assertEqual(result['systems']['local'][0]['diarization_error_rate'], 0)

    def test_refuse_unreviewed_or_selected_disagreements(self):
        for value in ({}, dict(status='reviewed', selection='diagnostic', reviewedRegions=[dict(start=0,end=1)])):
            with self.assertRaises(ValueError):
                score(value, {})

    def test_partial_review_does_not_score_unreviewed_audio(self):
        gold = dict(status='reviewed', selection='independent', audioDurationSeconds=10,
                    reviewedRegions=[dict(start=2, end=4)],
                    intervals=[dict(start=2, end=3, speaker='person'),
                               dict(start=5, end=9, speaker='other')])
        result = score(gold, {'local': [dict(start=2, end=3, speaker='a'),
                                         dict(start=6, end=10, speaker='b')]})
        view = result['systems']['local'][0]
        self.assertEqual(view['scored_wall_seconds'], 2)
        self.assertEqual(view['reference_speaker_seconds'], 1)
        self.assertEqual(view['diarization_error_rate'], 0)
        self.assertEqual(view['hypothesis_speaker_seconds_in_unknown_gaps'], 4)

    def test_silence_only_review_has_no_der_denominator(self):
        gold = dict(status='reviewed', selection='independent', audioDurationSeconds=4,
                    reviewedRegions=[dict(start=1, end=3)], intervals=[])
        for view in score(gold, {'local': [dict(start=0, end=4, speaker='a')]})['systems']['local']:
            self.assertEqual(view['extra_speaker_seconds'], 2)
            self.assertIsNone(view['diarization_error_rate'])

    def test_review_flags_and_coverage_required(self):
        gold = dict(status='reviewed', selection='independent', audioDurationSeconds=4,
                    reviewedRegions=[dict(start=0, end=4)], intervals=[])
        for changes in (dict(status='pending'), dict(selection='diagnostic'),
                        dict(reviewedRegions=[]), dict(reviewedRegions=None),
                        dict(reviewedRegions=[dict(start=0, end=5)])):
            with self.assertRaises(ValueError):
                score(gold | changes, {'local': []})
        with self.assertRaises(ValueError):
            score(gold, {})

    def test_private_paths_use_real_ignore_and_tracking_rules(self):
        # A separate synthetic repository keeps the real index and data untouched.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            (root / '.gitignore').write_text('/tmp/\n')
            (root / 'tmp').mkdir()
            tracked = root / 'tmp' / 'tracked.json'
            tracked.write_text('{}')
            subprocess.run(['git', 'add', '-f', '--', 'tmp/tracked.json'], cwd=root, check=True)
            alias = root / 'tmp' / 'alias'
            alias.symlink_to(root, target_is_directory=True)
            with patch('private_paths.ROOT', root):
                self.assertEqual(private_output(root / 'tmp' / 'new.json'), root / 'tmp' / 'new.json')
                # Brackets are literal filename characters, not a Git glob.
                self.assertEqual(private_output(root / 'tmp' / '[t]racked.json'),
                                 root / 'tmp' / '[t]racked.json')
                for path in (tracked, root / 'visible.json', alias / 'visible.json', root / 'tmp'):
                    with self.assertRaises(ValueError):
                        private_output(path)
                (root / '.gitignore').write_text('/tmp/*\n!/tmp/public.json\n')
                with self.assertRaises(ValueError):
                    private_output(root / 'tmp' / 'public.json')


if __name__ == '__main__':
    unittest.main()
