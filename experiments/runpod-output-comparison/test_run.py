"""Synthetic transport and submission safety checks; no credentials or network."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('comparison', Path(__file__).with_name('run.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RunnerTests(unittest.TestCase):
    def test_payload_keeps_track_identity_and_enables_diarization(self):
        body = runner.payload([
            {'track': 'track0', 'source': 'microphone', 'url': 'https://files.example/m.opus'},
            {'track': 'track1', 'source': 'system', 'url': 'https://files.example/s.opus'}], 'zh-cn')
        self.assertEqual(body['input']['diarize'], True)
        self.assertEqual(body['input']['language'], 'zh-cn')
        self.assertEqual([t['source_type'] for t in body['input']['tracks']], ['mic', 'system_mix'])
        self.assertNotIn('result_sink', body['input'])

    def test_endpoint_rejects_embedded_credentials_and_query(self):
        for value in ['http://example.com', 'https://user:secret@example.com', 'https://example.com?token=x']:
            with self.assertRaises(runner.Failure):
                runner.endpoint(value)

    def test_keychain_account_is_bound_to_kind_and_exact_endpoint(self):
        from types import SimpleNamespace
        p = {'id': 'abcd', 'kind': 'runpod', 'endpoint': 'https://api.example/endpoint'}
        with patch.object(runner.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout='synthetic-key\n')) as command:
            self.assertEqual(runner.credential(p), 'synthetic-key')
            first_account = command.call_args.args[0][-2]
            runner.credential({**p, 'endpoint': 'https://other.example/endpoint'})
            self.assertNotEqual(first_account, command.call_args.args[0][-2])
            self.assertEqual(command.call_args.args[0][1], 'find-generic-password')

    def test_upload_rejects_wrong_origin_size_and_expiry(self):
        valid = {'url': '/audio.opus?token=synthetic', 'size': 10, 'expires_in_secs': 60}
        self.assertTrue(runner.validated_upload(valid, 'https://files.example', 10)[0].startswith('https://files.example/'))
        for changed in [{'url': 'https://other.example/audio.opus'}, {'size': 9}, {'expires_in_secs': 0}]:
            with self.assertRaises(runner.Failure):
                runner.validated_upload({**valid, **changed}, 'https://files.example', 10)

    def test_output_counts_do_not_treat_blank_labels_as_diarized(self):
        result = runner.output_metrics({'output': {'tracks': {'track0': {'segments': [
            {'speaker': '', 'words': [{'word': 'Hello'}]}]}}}})
        self.assertEqual(result['track0']['labelled_words'], 0)
        self.assertEqual(result['track0']['labelled_segments'], 0)

    def test_ambiguous_submission_is_not_retried(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            audio = directory / 'track0.opus'
            audio.write_bytes(b'synthetic audio')
            state = {'phase': 'prepared', 'language': 'en', 'providers': {
                'runpod': {'endpoint': 'https://api.example/endpoint'},
                'filedrop': {'endpoint': 'https://files.example'}},
                'tracks': [{'track': 'track0', 'source': 'microphone', 'file': audio.name,
                            'bytes': audio.stat().st_size, 'sha256': runner.digest(audio)}]}
            runner.save(directory / 'state.json', state)
            def request(method, url, *args, **kwargs):
                if url.endswith('/info'):
                    return {'allowed_extensions': ['opus'], 'max_file_size_bytes': 1000}
                if '/upload?' in url:
                    return {'url': '/track0.opus', 'size': audio.stat().st_size, 'expires_in_secs': 60}
                self.assertEqual(runner.read(directory / 'state.json')['phase'], 'submission_started')
                raise runner.Failure('Synthetic ambiguous response')
            with patch.object(runner, 'credential', return_value='synthetic'), patch.object(runner, 'request', side_effect=request) as network:
                with self.assertRaises(runner.Failure):
                    runner.submit(directory)
                count = network.call_count
                with self.assertRaises(runner.Failure):
                    runner.submit(directory)
                self.assertEqual(network.call_count, count)
            self.assertEqual(runner.read(directory / 'state.json')['phase'], 'submission_started')

    def test_poll_preserves_unmodified_response(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            runner.save(directory / 'state.json', {'phase': 'submitted', 'job_id': 'synthetic?x#y%',
                        'providers': {'runpod': {'endpoint': 'https://api.example/endpoint'}}, 'tracks': [{'track': 'track0'}]})
            response = {'status': 'COMPLETED', 'output': {'tracks': {'track0': {'segments': [
                {'words': [{'word': 'Hello', 'speaker': 'mic_0', 'start': 1, 'end': 2}]}]}}}}
            with patch.object(runner, 'credential', return_value='synthetic'), patch.object(runner, 'request', return_value=response) as request:
                runner.poll(directory)
                self.assertTrue(request.call_args.args[1].endswith('/synthetic%3Fx%23y%25'))
            self.assertEqual(runner.read(directory / 'raw-response.json'), response)
            self.assertEqual(runner.read(directory / 'state.json')['phase'], 'completed')


if __name__ == '__main__':
    unittest.main()
