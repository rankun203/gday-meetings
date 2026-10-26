"""Synthetic review contracts: coverage, paths, and source/result consistency."""
import array
import wave
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import socket
import subprocess
import sys
import time
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

from review import build_payload, review_rows, mixed_recording, prepare_clip, load_variant, runtime_sections


class ReviewTests(unittest.TestCase):
    def fixture(self):
        return dict(meetings=[dict(id='m1', folder='meeting-a', meeting_order=0,
                                  metadata=dict(id='m1', title='Example meeting', audioFiles=['system.opus']), speakers=[])],
                    examples=[dict(id='e1', meetingID='m1', audioFile='system.opus',
                                   detectedSpeakerID='speaker-a', start=1, end=3, embeddings=[]),
                              dict(id='e2', meetingID='m1', audioFile='system.opus', start=5, end=7,
                                   spans=[dict(start=5, end=6), dict(start=7, end=8)])],
                    samples=[dict(id='e1', example_id='e1', audio_path='library/meetings/meeting-a/system.opus')])

    def test_late_fragmented_clip_seeks_and_omits_intervening_audio(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / 'source.wav'
            values = array.array('h', [100] * 16000 + [200] * 16000 + [300] * 16000 + [400] * 16000)
            with wave.open(str(source), 'wb') as audio:
                audio.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
                audio.writeframes(values.tobytes())
            output = root / 'clip.wav'
            prepare_clip(source, [dict(start=1.25, end=1.75), dict(start=3.25, end=3.75)], output)
            with wave.open(str(output), 'rb') as audio:
                actual = array.array('h', audio.readframes(audio.getnframes()))
            self.assertEqual(actual, array.array('h', [200] * 8000 + [400] * 8000))
            self.assertFalse(output.with_suffix('.partial.wav').exists())

    def test_mixed_playback_preserves_track_offsets_and_caches(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            recordings, tracks = {}, []
            for index, offset in enumerate([0, 1]):
                path = root / f'track-{index}.wav'
                with wave.open(str(path), 'wb') as audio:
                    audio.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
                    audio.writeframes(array.array('h', [1000] * 8000).tobytes())
                key = f'm1/{index}'
                recordings[key] = path
                tracks.append(dict(recording_key=key, recording_offset=offset))
            result = mixed_recording(root, 'm1', tracks, recordings)
            with wave.open(str(result), 'rb') as audio:
                self.assertEqual(audio.getnframes(), 24000)
                values = array.array('h', audio.readframes(audio.getnframes()))
                self.assertGreater(abs(values[4000]), 900)
                self.assertEqual(values[12000], 0)
                self.assertGreater(abs(values[20000]), 900)
            before = result.stat().st_mtime_ns
            self.assertEqual(mixed_recording(root, 'm1', tracks, recordings).stat().st_mtime_ns, before)

    def test_all_examples_remain_reviewable(self):
        rows = review_rows(self.fixture(), Path('/private/tmp/example'))
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]['local_label'], 'speaker-a')
        self.assertEqual(rows[1]['support_spans'], [dict(start=5, end=6), dict(start=7, end=8)])
        self.assertEqual(rows[1]['audio_path'], '/private/tmp/example/library/meetings/meeting-a/system.opus')
        self.assertNotEqual(rows[0]['physical_key'], rows[1]['physical_key'])

    def test_duplicate_audio_has_one_physical_key(self):
        source = self.fixture()
        source['examples'].append({**source['examples'][0], 'id': 'alias'})
        rows = review_rows(source, Path('/private/tmp/example'))
        by_id = {r['sample_id']: r for r in rows}
        self.assertEqual(by_id['e1']['physical_key'], by_id['alias']['physical_key'])

    def test_payload_hides_vectors_and_preserves_unembedded_records(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            path = root / 'input.json'
            path.write_text(json.dumps(self.fixture()))
            (root / 'results.json').write_text(json.dumps(dict(metadata=dict(input_sha256=hashlib.sha256(path.read_bytes()).hexdigest()))))
            payload = build_payload(root)
            self.assertEqual(len(payload['samples']), 2)
            self.assertNotIn('embeddings', payload['samples'][0])
            self.assertNotIn('audio_path', payload['samples'][0])
            self.assertEqual(payload['meetings'][0]['title'], 'Example meeting')

    def test_runtime_sections_keep_identity_and_split_current_evidence(self):
        payload = dict(dataset='stable-source-hash', meetings=[dict(id='meeting')], people=[], availability={},
                       samples=[dict(sample_id='a', meeting_id='meeting'), dict(sample_id='b', meeting_id='meeting')],
                       transcripts=dict(rows=[dict(id='row', meeting_id='meeting', start=10, end=14,
                           track_index=1, audio_start=2, coverage_intervals=[dict(sample_id='a', start=10, end=12)])]),
                       results=dict(method_catalog=[dict(id='current_local_library')],
                           methods=dict(current_local_library=dict(assignments={'a': {'group': 'voice'}}, metrics={})),
                           pair_review=dict(pairs=[dict(sample_ids=['a'])]), scenarios=[dict(name='arrival')]))
        first = payload['transcripts']['rows'][0]
        payload['transcripts']['rows'] += [
            {**first, 'id': 'wrong-meeting', 'meeting_id': 'other', 'end': 30,
             'coverage_intervals': [dict(sample_id='a', start=10, end=30)]},
            {**first, 'id': 'invalid', 'start': float('nan')},
            {**first, 'id': 'later-tie', 'start': 11, 'audio_start': 3,
             'coverage_intervals': [dict(sample_id='a', start=11, end=13), dict(sample_id='a', start=11, end=12)]},
        ]
        responses = runtime_sections(payload)
        bootstrap = json.loads(responses['/data.json'])
        self.assertEqual(bootstrap['dataset'], payload['dataset'])
        self.assertNotIn('samples', bootstrap)
        self.assertNotIn('transcripts', bootstrap)
        self.assertNotIn('assignments', bootstrap['results']['methods']['current_local_library'])
        self.assertNotIn('pair_review', bootstrap['results'])
        compare = json.loads(responses['/section/compare.json'])
        self.assertEqual(compare['samples'], [dict(sample_id='a', meeting_id='meeting')])
        self.assertEqual(compare['pair_contexts']['a']['time'], 2)
        self.assertEqual(compare['pair_contexts']['a']['row'], 'row')
        self.assertNotIn('transcripts', compare)
        self.assertEqual(json.loads(responses['/method/current_local_library.json'])['assignments'], {'a': {'group': 'voice'}})
        first['audio_start'], first['recording_offset'] = None, float('nan')
        self.assertEqual(json.loads(runtime_sections(payload)['/section/compare.json'])['pair_contexts']['a']['time'], 10)
        payload['results'].pop('method_catalog')
        with self.assertRaisesRegex(ValueError, 'current model catalog'):
            runtime_sections(payload)

    def test_mismatched_results_refuse_to_start(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'input.json').write_text(json.dumps(self.fixture()))
            (root / 'results.json').write_text(json.dumps(dict(metadata=dict(input_sha256='old'))))
            with self.assertRaisesRegex(ValueError, 'do not match'):
                build_payload(root)

    def test_variants_require_catalog_identity_and_confined_files(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            relative = 'variants/global_dbscan_example/s080_m3.json'
            path = root / relative
            path.parent.mkdir(parents=True)
            value = dict(method='global_dbscan_example', variant='s080_m3', assignments={'sample': {'group': 'group'}})
            path.write_text(json.dumps(value))
            entry = dict(id='s080_m3', path=relative)
            results = dict(method_catalog=[dict(id='global_dbscan_example', variants=[entry])])
            self.assertEqual(load_variant(root, results, 'global_dbscan_example', 's080_m3'), value)
            entry['sha256'] = 'changed'
            with self.assertRaisesRegex(ValueError, 'changed after'):
                load_variant(root, results, 'global_dbscan_example', 's080_m3')
            entry.pop('sha256')
            for method, variant in [('unknown', 's080_m3'), ('global_dbscan_example', 'unknown'), ('../outside', 's080_m3')]:
                with self.assertRaises(ValueError):
                    load_variant(root, results, method, variant)
            for invalid in ['../outside.json', str(path), 'variants/another/s080_m3.json']:
                entry['path'] = invalid
                with self.assertRaisesRegex(ValueError, 'invalid path'):
                    load_variant(root, results, 'global_dbscan_example', 's080_m3')
            entry['path'] = relative
            path.write_text(json.dumps({**value, 'variant': 'different'}))
            with self.assertRaisesRegex(ValueError, 'identity'):
                load_variant(root, results, 'global_dbscan_example', 's080_m3')
            path.unlink()
            with tempfile.TemporaryDirectory() as outside:
                target = Path(outside) / 'outside.json'
                target.write_text(json.dumps(value))
                path.symlink_to(target)
                with self.assertRaisesRegex(ValueError, 'unavailable'):
                    load_variant(root, results, 'global_dbscan_example', 's080_m3')

    def test_feedback_save_conflict_and_origin(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            audio = root / 'library/meetings/meeting-a/system.opus'
            audio.parent.mkdir(parents=True)
            audio.write_bytes(b'0123456789')
            path = root / 'input.json'
            path.write_text(json.dumps(self.fixture()))
            variant_path = root / 'variants/global_dbscan_example/s080_m3.json'
            variant_path.parent.mkdir(parents=True)
            variant_value = dict(method='global_dbscan_example', variant='s080_m3', assignments={})
            variant_path.write_text(json.dumps(variant_value))
            (root / 'results.json').write_text(json.dumps(dict(
                metadata=dict(input_sha256=hashlib.sha256(path.read_bytes()).hexdigest()),
                methods={'global_dbscan_example': {'assignments': {}}},
                method_catalog=[dict(id='global_dbscan_example', variants=[dict(
                    id='s080_m3', path='variants/global_dbscan_example/s080_m3.json')])],
            )))
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0))
                port = sock.getsockname()[1]
            url = f'http://127.0.0.1:{port}'
            feedback_directory = root / 'isolated-feedback'
            process = subprocess.Popen([sys.executable, str(Path(__file__).with_name('review.py')),
                                        '--root', str(root), '--port', str(port),
                                        '--feedback-directory', str(feedback_directory)], stdout=subprocess.DEVNULL)
            try:
                for _ in range(100):
                    try:
                        with urlopen(url + '/feedback.json', timeout=1) as response:
                            initial = json.load(response)
                        break
                    except URLError:
                        time.sleep(.02)
                else:
                    self.fail('Review server did not start')
                with urlopen(url + '/variant/global_dbscan_example/s080_m3.json') as response:
                    self.assertEqual(json.load(response), variant_value)
                with urlopen(url + '/data.json') as response:
                    bootstrap = json.load(response)
                    self.assertNotIn('samples', bootstrap)
                    self.assertNotIn('assignments', bootstrap['results']['methods']['global_dbscan_example'])
                    self.assertFalse(bootstrap['has_pair_review'])
                    self.assertEqual(bootstrap['dataset'], initial['dataset'])
                with urlopen(url + '/sample/e1.json?global_dbscan_example=s080_m3') as response:
                    self.assertEqual(json.load(response), [dict(method='global_dbscan_example', variant='s080_m3', assignment=None)])
                with urlopen(url + '/method/global_dbscan_example.json') as response:
                    self.assertEqual(json.load(response), dict(assignments={}))
                for route in ['/variant/global_dbscan_example/unknown.json',
                              '/variant/unknown/s080_m3.json',
                              '/variant/global_dbscan_example/%2e%2e%2foutside.json']:
                    with self.assertRaises(HTTPError) as blocked_variant:
                        urlopen(url + route)
                    self.assertEqual(blocked_variant.exception.code, 422)
                simulation = {'groups': {'global_dbscan_unique': {'group-a': {'person': 'Example Person'}}},
                              'history': [{'method': 'global_dbscan_unique', 'group': 'group-a', 'before': None}]}
                body = {**initial, 'notes': 'Example feedback', 'simulation': simulation,
                        'reviews': {'e1': {'person': 'Another Person', 'personOverride': True}},
                        'transcriptReviews': {'global_dbscan_unique': {'m1:r1': {'verdict': 'wrong_person'}}},
                        'transcriptCorrections': {'m1:r1': {'person': 'Example Speaker'}},
                        'intervalTruth': {'interval-a': {'scope': 'recording-a', 'row_id': 'm1:r1', 'start': 1.125, 'end': 2.875, 'kind': 'person', 'person': 'Example Speaker'}},
                        'intervalReviews': {'global_dbscan_unique': {'interval-a': {'verdict': 'wrong', 'prediction': {'kind': 'group', 'group': 'group-a'}}}},
                        'intervalHistory': [{'key': 'interval-a', 'method': 'global_dbscan_unique', 'previousReview': None, 'truthKeys': ['interval-a'], 'previousTruth': {'interval-a': None}}],
                        'pairReviews': {'pair-a': {'sample_ids': ['e1', 'e2'], 'verdict': 'different'}},
                        'samplePeople': {'e1': {'person': 'Example Person'}},
                        'pairHistory': [{'kind': 'pair-review', 'pair': 'pair-a', 'previous': None}]}
                def save(origin):
                    return urlopen(Request(url + '/feedback.json', data=json.dumps(body).encode(),
                                           headers={'Origin': origin, 'Content-Type': 'application/json'}))
                with self.assertRaises(HTTPError) as blocked:
                    save('https://example.com')
                self.assertEqual(blocked.exception.code, 403)
                with save(url) as response:
                    self.assertEqual(json.load(response)['revision'], 1)
                with self.assertRaises(HTTPError) as conflict:
                    save(url)
                self.assertEqual(conflict.exception.code, 409)
                with urlopen(url + '/feedback.json') as response:
                    saved = json.load(response)
                    self.assertEqual(saved['notes'], 'Example feedback')
                    self.assertEqual(saved['simulation'], simulation)
                    self.assertEqual(saved['reviews']['e1']['person'], 'Another Person')
                    self.assertEqual(saved['transcriptReviews'], body['transcriptReviews'])
                    self.assertEqual(saved['transcriptCorrections'], body['transcriptCorrections'])
                    self.assertEqual(saved['pairReviews'], body['pairReviews'])
                    self.assertEqual(saved['samplePeople'], body['samplePeople'])
                    self.assertEqual(saved['pairHistory'], body['pairHistory'])
                    for key in ['intervalTruth', 'intervalReviews', 'intervalHistory']:
                        self.assertEqual(saved[key], body[key])
                self.assertEqual(len(list(feedback_directory.glob('feedback-*.json'))), 1)
                self.assertEqual(len(list(root.glob('feedback-*.json'))), 0)
                # A prepared clip must support seeking before playback begins.
                clip_name = hashlib.sha256(json.dumps([str(audio.resolve()), [dict(start=1, end=3)]]).encode()).hexdigest()
                (root / 'clips' / (clip_name + '.wav')).write_bytes(b'0123456789')
                with urlopen(Request(url + '/clip/e1.wav', headers={'Range': 'bytes=3-6'})) as response:
                    self.assertEqual(response.status, 206)
                    self.assertEqual(response.read(), b'3456')
                    self.assertEqual(response.headers['Content-Range'], 'bytes 3-6/10')
                    self.assertEqual(response.headers['Accept-Ranges'], 'bytes')
                with urlopen(Request(url + '/recording/m1/0', headers={'Range': 'bytes=3-6'})) as response:
                    self.assertEqual(response.status, 206)
                    self.assertEqual(response.read(), b'3456')
                    self.assertEqual(response.headers['Content-Range'], 'bytes 3-6/10')
            finally:
                process.terminate()
                process.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()
