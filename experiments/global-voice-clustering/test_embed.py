"""Checkpoint recovery checks for interrupted offline extraction."""
import json
import struct
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

from embed import read_results, decode_aac_jobs, canonical_wav_frames, recover_eof_jobs


class CheckpointTests(unittest.TestCase):
    def test_repeated_jobs_decode_and_hash_each_audio_file_once(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            original = root / 'track.m4a'
            original.write_bytes(b'synthetic audio')
            jobs = [dict(audioPath=str(original)) for _ in range(100)]
            def run(command, **kwargs):
                if '-version' in command:
                    return SimpleNamespace(stdout='ffmpeg synthetic\n')
                Path(command[-1]).write_bytes(b'decoded synthetic audio')
                return SimpleNamespace(returncode=0)
            with patch('embed.subprocess.run', side_effect=run) as process, patch('embed.file_sha256', return_value='hash') as digest:
                decode_aac_jobs(jobs, root)
            self.assertEqual(process.call_count, 2)
            self.assertEqual(digest.call_count, 2)
            self.assertEqual(len({j['audioPath'] for j in jobs}), 1)
            self.assertTrue(all(j['originalAudioPath'] == str(original) for j in jobs))

    def test_torn_tail_preserves_completed_vector(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'results.jsonl'
            row = dict(key='sample-a', embedding=dict(values=[1., 0.]))
            complete = json.dumps(row).encode() + b'\n'
            path.write_bytes(complete + b'{"key":"sample-b')
            self.assertEqual(read_results(path, repair=True), {'sample-a': row})
            self.assertEqual(path.read_bytes(), complete)

    def test_interior_corruption_is_not_silently_discarded(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'results.jsonl'
            raw = b'broken\n{"key":"sample-a"}\n'
            path.write_bytes(raw)
            with self.assertRaisesRegex(ValueError, 'interior'):
                read_results(path, repair=True)
            self.assertEqual(path.read_bytes(), raw)

    def test_successful_retry_supersedes_failed_attempt(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'results.jsonl'
            path.write_text('{"key":"sample-a","error":"conversion failed"}\n'
                            '{"key":"sample-a","embedding":{"values":[1,0]}}')
            self.assertIn('embedding', read_results(path, repair=True)['sample-a'])
            self.assertTrue(path.read_bytes().endswith(b'\n'))


def float_wav(frames):
    payload = b'\0' * (frames * 4)
    fmt = struct.pack('<HHIIHH', 3, 1, 16000, 64000, 4, 32)
    body = b'WAVEfmt ' + struct.pack('<I', len(fmt)) + fmt + b'data' + struct.pack('<I', len(payload)) + payload
    return b'RIFF' + struct.pack('<I', len(body)) + body


class CanonicalFallbackTests(unittest.TestCase):
    def prepare(self, root):
        original = root / 'source.m4a'
        original.write_bytes(b'synthetic AAC source')
        decoded = root / 'primary.wav'
        decoded.write_bytes(b'synthetic source-rate decoded audio')
        binary = root / 'extractor'
        binary.write_bytes(b'synthetic binary')
        input_path = root / 'input.json'
        input_path.write_text('{}')
        job = dict(key='synthetic-key', originalAudioPath=str(original), audioPath=str(decoded),
                   spans=[dict(start=0, end=.01)])
        jobs_path = root / 'embedding-jobs.json'
        jobs_path.write_text(json.dumps([job]))
        from embed import file_sha256
        manifest = dict(recordings=[dict(status='complete', audio_sha256=file_sha256(original), decoded_samples=160)])
        (root / 'full-speech-manifest.json').write_text(json.dumps(manifest))
        results_path = root / 'embedding-results.jsonl'
        failed = dict(key=job['key'], error='The excerpt is outside the decoded audio.', seconds=.1)
        results_path.write_text(json.dumps(failed) + '\n')
        return original, binary, input_path, jobs_path, results_path, job

    def runner(self, command, **kwargs):
        if '-version' in command:
            return SimpleNamespace(stdout='ffmpeg synthetic\n')
        if command[0] == 'ffmpeg':
            Path(command[-1]).write_bytes(float_wav(160))
            return SimpleNamespace(returncode=0)
        jobs = json.loads(Path(command[1]).read_text())
        with Path(command[3]).open('a') as handle:
            for job in jobs:
                handle.write(json.dumps(dict(key=job['key'], embedding=dict(values=[1., 0.], type={'synthetic': True}), seconds=.2)) + '\n')
        return SimpleNamespace(stderr='', check_returncode=lambda: None)

    def test_canonical_decode_preserves_spans_and_original_failure(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            original, binary, input_path, jobs_path, results_path, job = self.prepare(root)
            before = results_path.read_bytes()
            primary = {'synthetic': 'unchanged sources and models'}
            with patch('embed.subprocess.run', side_effect=self.runner), patch('embed.provenance', return_value=primary):
                summary = recover_eof_jobs(root, input_path, jobs_path, root / 'models', binary, results_path, primary)
            self.assertEqual(summary['recovered'], 1)
            self.assertTrue(results_path.read_bytes().startswith(before))
            self.assertIn('embedding', read_results(results_path)[job['key']])
            fallback_jobs = json.loads((root / 'embedding-fallback/jobs.json').read_text())
            self.assertEqual(fallback_jobs[0]['spans'], job['spans'])
            self.assertEqual(fallback_jobs[0]['key'], job['key'])
            self.assertEqual(json.loads(jobs_path.read_text()), [job])
            receipt = json.loads((root / 'embedding-fallback/receipt.json').read_text())
            source = next(iter(receipt['sources'].values()))
            self.assertEqual(source['decoded_samples'], 160)
            self.assertEqual(source['vad_decoded_samples'], 160)
            self.assertIn('-ar', source['command'])
            merged = results_path.read_bytes()
            def resumed(command, **kwargs):
                self.assertIn('-version', command, 'Completed fallback must avoid another inference run.')
                return self.runner(command, **kwargs)
            with patch('embed.subprocess.run', side_effect=resumed), patch('embed.provenance', return_value=primary):
                recovered_summary = recover_eof_jobs(root, input_path, jobs_path, root / 'models', binary, results_path, primary)
            self.assertEqual(recovered_summary, summary)
            self.assertEqual(results_path.read_bytes(), merged)
            # Resume still verifies the prepared audio after the journal merge.
            Path(fallback_jobs[0]['audioPath']).write_bytes(b'changed')
            with patch('embed.subprocess.run', side_effect=resumed), patch('embed.provenance', return_value=primary):
                with self.assertRaisesRegex(ValueError, 'decoded checkpoint changed'):
                    recover_eof_jobs(root, input_path, jobs_path, root / 'models', binary, results_path, primary)

    def test_model_change_blocks_merge_then_verified_checkpoint_recovers(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            original, binary, input_path, jobs_path, results_path, job = self.prepare(root)
            before = results_path.read_bytes()
            primary = {'model': 'original'}
            with patch('embed.subprocess.run', side_effect=self.runner), patch('embed.provenance', return_value={'model': 'changed'}):
                with self.assertRaisesRegex(ValueError, 'source or model changed'):
                    recover_eof_jobs(root, input_path, jobs_path, root / 'models', binary, results_path, primary)
            self.assertEqual(results_path.read_bytes(), before)
            receipt_before = (root / 'embedding-fallback/receipt.json').read_bytes()
            with patch('embed.subprocess.run', side_effect=self.runner), patch('embed.provenance', return_value=primary):
                self.assertEqual(recover_eof_jobs(root, input_path, jobs_path, root / 'models', binary, results_path, primary)['recovered'], 1)
            self.assertEqual((root / 'embedding-fallback/receipt.json').read_bytes(), receipt_before)

    def test_partial_merge_retains_original_job_plan(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            original, binary, input_path, jobs_path, results_path, job = self.prepare(root)
            second = {**job, 'key': 'synthetic-second'}
            jobs_path.write_text(json.dumps([job, second]))
            with results_path.open('a') as handle:
                handle.write(json.dumps(dict(key=second['key'], error='The excerpt is outside the decoded audio.', seconds=.1)) + '\n')
            primary = {'source': 'stable'}
            # Simulate a crash before verified merge by rejecting the first provenance check.
            with patch('embed.subprocess.run', side_effect=self.runner), patch('embed.provenance', return_value={'source': 'changed'}):
                with self.assertRaisesRegex(ValueError, 'source or model changed'):
                    recover_eof_jobs(root, input_path, jobs_path, root / 'models', binary, results_path, primary)
            fallback = read_results(root / 'embedding-fallback/results.jsonl')
            with results_path.open('a') as handle:
                handle.write(json.dumps(fallback[job['key']]) + '\n')
            old_plan = (root / 'embedding-fallback/jobs.json').read_bytes()
            with patch('embed.subprocess.run', side_effect=self.runner), patch('embed.provenance', return_value=primary):
                summary = recover_eof_jobs(root, input_path, jobs_path, root / 'models', binary, results_path, primary)
            self.assertEqual(summary['recovered'], 2)
            self.assertEqual(summary['unresolved'], 0)
            self.assertEqual((root / 'embedding-fallback/jobs.json').read_bytes(), old_plan)
            journal = [json.loads(line) for line in results_path.read_text().splitlines()]
            self.assertEqual(sum(row['key'] == job['key'] and bool(row.get('embedding')) for row in journal), 1)
            self.assertTrue(all(row.get('embedding') for row in read_results(results_path).values()))

    def test_short_decode_refuses_to_clamp_speech(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            original, binary, input_path, jobs_path, results_path, job = self.prepare(root)
            before = results_path.read_bytes()
            def shorter(command, **kwargs):
                if command[0] == 'ffmpeg' and '-version' not in command:
                    Path(command[-1]).write_bytes(float_wav(159))
                    return SimpleNamespace(returncode=0)
                return self.runner(command, **kwargs)
            with patch('embed.subprocess.run', side_effect=shorter):
                with self.assertRaisesRegex(ValueError, 'differs from the VAD sample count'):
                    recover_eof_jobs(root, input_path, jobs_path, root / 'models', binary, results_path, {})
            self.assertEqual(results_path.read_bytes(), before)
            self.assertFalse((root / 'embedding-fallback/receipt.json').exists())

    def test_truncated_wav_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'audio.wav'
            path.write_bytes(float_wav(160))
            self.assertEqual(canonical_wav_frames(path), 160)
            path.write_bytes(path.read_bytes()[:-4])
            with self.assertRaisesRegex(ValueError, 'truncated'):
                canonical_wav_frames(path)


if __name__ == '__main__':
    unittest.main()
