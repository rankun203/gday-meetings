import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import wave

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from build_review import build, export_review, select_random, validate_output, intervals
import private_paths


class ReviewTests(unittest.TestCase):
    def test_current_offline_window_metadata(self):
        row = dict(start_seconds=0, end_seconds=1, speaker='a', update_id=0,
                   window_end_seconds=2, provisional=False)
        self.assertEqual(len(intervals([row], 2, model=True)), 1)
        for changes in (dict(provisional=True), dict(update_id=1)):
            with self.assertRaises(ValueError):
                intervals([row | changes], 2, model=True)

    def test_deterministic_uniform_and_nonoverlap(self):
        self.assertEqual(select_random(1000, 100, 4, 9), select_random(1000, 100, 4, 9))
        seen = set()
        for seed in range(100):
            clips = select_random(1000, 100, 4, seed)
            seen.update(a for a, _ in clips)
            self.assertTrue(all(b - a == 100 for a, b in clips))
            self.assertTrue(all(a[1] <= b[0] for a, b in zip(clips, clips[1:])))
        self.assertEqual(seen, set(range(0, 1000, 100)))

    def test_coverage_short_and_invalid(self):
        self.assertEqual(select_random(1000, 100, 100, 0), [(i, i + 100) for i in range(0, 1000, 100)])
        self.assertEqual(select_random(31, 100, 8, 0), [(0, 31)])
        self.assertTrue(all(0 <= a < b <= 1003 for a, b in select_random(1003, 100, 10, 0)))
        for args in ((0, 1, 1, 0), (1, 0, 1, 0), (1, 1, 0, 0)):
            with self.assertRaises(ValueError):
                select_random(*args)

    def fixture(self, root):
        audio, ref, model = root / 'audio.wav', root / 'reference.json', root / 'model.jsonl'
        with wave.open(str(audio), 'wb') as handle:
            handle.setparams((1, 2, 100, 0, 'NONE', 'not compressed'))
            handle.writeframes(b'\x00\x01' * 1000)
        ref.write_text(json.dumps(dict(audioDurationSeconds=10, intervals=[dict(start=0, end=10, speaker='reference')])) )
        model.write_text(json.dumps(dict(start_seconds=0, end_seconds=5, speaker='model')))
        return audio, ref, model

    def test_blinding_selection_extraction_and_export(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            audio, ref, model = self.fixture(root)
            key = build(audio, ref, [model], root / 'set', 2, 2, 2, 7)
            blind = root / 'set/blind/annotations.json'
            templates = json.loads(blind.read_text())
            self.assertNotIn(str(root), blind.read_text())
            self.assertNotIn('reference', blind.read_text())
            for clip in templates['clips']:
                self.assertEqual(clip['intervals'], [])
                self.assertEqual(clip['reviewedRegions'], [])
                with wave.open(str(blind.parent / clip['audio'])) as wav:
                    self.assertEqual(wav.getnframes(), 200)
                    self.assertEqual(wav.readframes(200), b'\x00\x01' * 200)
            spans = sorted((c['startFrame'], c['endFrame']) for c in key['clips'])
            self.assertTrue(all(a[1] <= b[0] for a, b in zip(spans, spans[1:])))
            with self.assertRaises(ValueError):
                export_review(root / 'set', root / 'export')
            for clip in templates['clips']:
                clip.update(status='reviewed', reviewedRegions=[dict(start=0, end=1)],
                            intervals=[dict(start=0, end=0.5, speaker='person-01')])
            blind.write_text(json.dumps(templates))
            gold = export_review(root / 'set', root / 'export')
            self.assertEqual(len(gold['reviewedRegions']), 2)
            self.assertEqual(gold['selection'], 'independent')
            self.assertTrue((root / 'export/system-00.json').exists())
            self.assertTrue((root / 'export/system-01.json').exists())
            model.write_text('')
            changed = build(audio, ref, [model], root / 'changed', 2, 2, 2, 7)
            primary = lambda k: sorted((c['startFrame'], c['endFrame']) for c in k['clips'] if c['category'] == 'random')
            self.assertEqual(primary(key), primary(changed))
            with self.assertRaises(ValueError):
                build(audio, ref, [model], root / 'set', 2, 2, 0, 7)

    def test_short_clip_and_invalid_review_regions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            audio, ref, model = self.fixture(root)
            key = build(audio, ref, [model], root / 'set', 20, 10, 2, 0)
            self.assertEqual(len(key['clips']), 1)
            path = root / 'set/blind/annotations.json'
            annotations = json.loads(path.read_text())
            clip = annotations['clips'][0]
            self.assertEqual(clip['durationSeconds'], 10)
            for regions in ([], [dict(start=0, end=11)],
                            [dict(start=0, end=2), dict(start=1, end=3)]):
                clip.update(status='reviewed', reviewedRegions=regions)
                path.write_text(json.dumps(annotations))
                with self.assertRaises(ValueError):
                    export_review(root / 'set', root / 'export')
                self.assertFalse((root / 'export').exists())

    def test_invalid_inputs_do_not_create_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            audio, ref, model = self.fixture(root)
            for row in (dict(start_seconds=0, end_seconds=11, speaker='x'),
                        dict(start_seconds=0, end_seconds=1, speaker='x', update_id=1),
                        dict(start_seconds=float('nan'), end_seconds=1, speaker='x')):
                model.write_text(json.dumps(row))
                with self.assertRaises(ValueError):
                    build(audio, ref, [model], root / 'set')
                self.assertFalse((root / 'set').exists())

    def test_interval_start_at_or_beyond_duration(self):
        for start in (10, 10 + 0.25e-6):
            with self.assertRaises(ValueError):
                intervals([dict(start=start, end=10 + 0.5e-6, speaker='x')], 10)
        self.assertEqual(intervals([dict(start=9, end=10 + 0.5e-6, speaker='x')], 10)[0]['end'], 10)

    def test_reference_hash_mismatch_creates_no_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            audio, ref, model = self.fixture(root)
            reference = json.loads(ref.read_text())
            reference['preparedAudioSHA256'] = '0' * 64
            ref.write_text(json.dumps(reference))
            with self.assertRaisesRegex(ValueError, 'Prepared audio SHA256'):
                build(audio, ref, [model], root / 'set')
            self.assertFalse((root / 'set').exists())
            reference['preparedAudioSHA256'] = hashlib.sha256(audio.read_bytes()).hexdigest()
            ref.write_text(json.dumps(reference))
            key = build(audio, ref, [model], root / 'set', 20, 1, 0)
            self.assertEqual(key['audio_sha256'], reference['preparedAudioSHA256'])
            for system, path in zip(key['systems'], (ref, model)):
                self.assertEqual(system['sha256'], hashlib.sha256(path.read_bytes()).hexdigest())
            wav = root / 'set/blind' / (key['clips'][0]['id'] + '.wav')
            self.assertEqual(key['clips'][0]['wavSHA256'], hashlib.sha256(wav.read_bytes()).hexdigest())

    def test_export_provenance_mismatch_creates_no_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            audio, ref, model = self.fixture(root)
            build(audio, ref, [model], root / 'set', 20, 1, 0)
            path = root / 'set/blind/annotations.json'
            annotations = json.loads(path.read_text())
            clip = annotations['clips'][0]
            clip.update(status='reviewed', reviewedRegions=[dict(start=0, end=10)])
            for duration in (9, float('nan'), float('inf')):
                clip['durationSeconds'] = duration
                path.write_text(json.dumps(annotations))
                with self.assertRaisesRegex(ValueError, 'Annotation duration'):
                    export_review(root / 'set', root / 'export')
                self.assertFalse((root / 'export').exists())
            clip['durationSeconds'] = 10
            path.write_text(json.dumps(annotations))
            wav = root / 'set/blind' / clip['audio']
            original = wav.read_bytes()
            wav.write_bytes(original[:-1] + bytes([original[-1] ^ 1]))
            with self.assertRaisesRegex(ValueError, 'Clip WAV SHA256'):
                export_review(root / 'set', root / 'export')
            self.assertFalse((root / 'export').exists())
            wav.write_bytes(original)
            self.assertEqual(export_review(root / 'set', root / 'export')['status'], 'reviewed')

    def test_path_policy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            repo = root / 'repo'
            repo.mkdir()
            subprocess.run(['git', 'init', '-q', str(repo)], check=True)
            (repo / '.gitignore').write_text('/tmp/\n')
            with patch.object(private_paths, 'ROOT', repo):
                self.assertEqual(validate_output(repo / 'tmp/review', ['blind/a.wav']), repo / 'tmp/review')
                with self.assertRaises(ValueError):
                    validate_output(repo / 'results', ['a.wav'])
                (repo / '.gitignore').write_text('')
                with self.assertRaises(ValueError):
                    validate_output(repo / 'tmp/review', ['a.wav'])
                alias = root / 'alias'
                alias.symlink_to(repo, target_is_directory=True)
                with self.assertRaises(ValueError):
                    validate_output(alias / 'results', ['a.wav'])
                self.assertEqual(validate_output(root / 'outside', ['a.wav']), root / 'outside')


if __name__ == '__main__':
    unittest.main()
