"""Synthetic persistence, blindness, audio, and scoring checks."""
import hashlib
import http.client
import json
import math
from pathlib import Path
import shutil
import struct
import tempfile
import threading
import unittest
import wave

from server import ROOT, ReviewError, Store, make_server


def fixture(directory, duration=2):
    sample = directory / 'sample-demo'
    (sample / 'blind').mkdir(parents=True)
    (sample / 'private').mkdir()
    clips, selections = [], []
    for index in range(1, 3):
        name = f'clip-{index:04d}'
        path = sample / 'blind' / f'{name}.wav'
        with wave.open(str(path), 'wb') as audio:
            audio.setparams((1, 2, 8000, 0, 'NONE', 'not compressed'))
            samples = [round(6500 * math.sin(2 * math.pi * (220 + index * 110) * frame / 8000))
                       if (frame // 2400) % 3 else 0 for frame in range(8000 * duration)]
            audio.writeframes(struct.pack(f'<{len(samples)}h', *samples))
        clips.append(dict(id=name, audio=path.name, durationSeconds=float(duration), status='unreviewed',
                          instructions='Listen to this synthetic clip.', intervals=[], reviewedRegions=[]))
        selections.append(dict(id=name, category='random' if index == 1 else 'diagnostic',
                               startSeconds=duration * (index - 1), endSeconds=duration * index,
                               wavSHA256=hashlib.sha256(path.read_bytes()).hexdigest(),
                               systems={'system-00': [{'start': 0, 'end': 1, 'speaker': 'original'}]}))
    (sample / 'blind/annotations.json').write_text(json.dumps(dict(schema_version=1, clips=clips)))
    (sample / 'private/key.json').write_text(json.dumps(dict(audioDurationSeconds=duration * 2, systems=[dict(id='system-00', path='private-source', role='model')], clips=selections)))
    return directory


class StoreTests(unittest.TestCase):
    def setUp(self):
        (ROOT / 'tmp').mkdir(exist_ok=True)
        self.directory = Path(tempfile.mkdtemp(prefix='review-test-', dir=ROOT / 'tmp'))
        fixture(self.directory)
        self.store = Store(self.directory)

    def tearDown(self):
        shutil.rmtree(self.directory)

    def reviewed(self):
        data = self.store.read('sample-demo')
        for clip in data['clips']:
            clip.update(status='reviewed', intervals=[dict(start=0, end=1, speaker='Speaker 1'), dict(start=.5, end=1, speaker='Speaker 2')],
                        reviewedRegions=[dict(start=0, end=1.5)], uncertainRegions=[dict(start=1.5, end=2)])
        data['speakerReferences'] = [dict(speaker='Speaker 1', clip='clip-0001', start=0, end=.5)]
        return data

    def test_blind_metadata(self):
        path = self.store.annotation('sample-demo')
        original = json.loads(path.read_bytes())
        original['clips'][0]['intervals'] = [dict(start=0, end=1, speaker='Speaker 1', prediction='hidden-metadata')]
        original['clips'][0]['reviewedRegions'] = [dict(start=0, end=1, category='hidden-metadata')]
        original['speakerReferences'] = [dict(start=0, end=1, speaker='Speaker 1', clip='clip-0001', source='hidden-metadata')]
        path.write_text(json.dumps(original))
        data = json.dumps([self.store.read('sample-demo'), self.store.listing()])
        for secret in ('diagnostic', 'random', 'system-00', 'private-source', 'original', 'hidden-metadata'):
            self.assertNotIn(secret, data)

    def test_save_backup_and_conflict(self):
        old = self.store.annotation('sample-demo').read_bytes()
        data = self.reviewed()
        saved = self.store.save('sample-demo', data)
        self.assertNotEqual(saved['revision'], data['revision'])
        self.assertEqual(saved['speakerReferences'], data['speakerReferences'])
        self.assertEqual(list((self.directory / 'sample-demo/blind/backups').glob('*.json'))[0].read_bytes(), old)
        with self.assertRaises(ReviewError) as error:
            self.store.save('sample-demo', data)
        self.assertEqual(error.exception.status, 409)
        self.assertIn('instructions', json.loads(self.store.annotation('sample-demo').read_bytes())['clips'][0])

    def test_invalid_ranges_and_immutable_fields(self):
        changes = [('durationSeconds', 4), ('audio', '../key.json'), ('id', 'other'),
                   ('status', 'complete'), ('intervals', [dict(start=0, end=float('nan'), speaker='a')]),
                   ('reviewedRegions', [dict(start=0, end=3)]),
                   ('uncertainRegions', [dict(start=0, end=1)])]
        for key, value in changes:
            with self.subTest(key=key):
                data = self.reviewed()
                data['clips'][0][key] = value
                with self.assertRaises(ReviewError):
                    self.store.save('sample-demo', data)

    def test_conflict_draft_preserves_saved_review(self):
        draft = self.reviewed()
        self.store.save('sample-demo', draft)
        before = self.store.annotation('sample-demo').read_bytes()
        draft['clips'][0]['intervals'] = []
        result = self.store.save('sample-demo', draft, draft=True)
        self.assertEqual(self.store.annotation('sample-demo').read_bytes(), before)
        saved = json.loads((ROOT / result['output']).read_text())
        self.assertEqual(saved['clips'][0]['intervals'], [])
        self.assertEqual(saved['draftBaseRevision'], draft['revision'])
        self.assertNotEqual(result['output'], self.store.save('sample-demo', draft, draft=True)['output'])

    def test_export_excludes_diagnostics_and_uncertainty(self):
        with self.assertRaises(ReviewError):
            self.store.export('sample-demo')
        self.store.save('sample-demo', self.reviewed())
        result = self.store.export('sample-demo')
        gold = json.loads((ROOT / result['output'] / 'gold.json').read_text())
        self.assertEqual(gold['reviewedRegions'], [dict(start=0, end=1.5)])
        self.assertEqual(len(gold['intervals']), 2)
        self.assertIn('systems', result['results'])
        self.assertEqual(result['results']['systemLabels'], {'system-00': 'Local Model 1'})
        self.assertNotEqual(result['output'], self.store.export('sample-demo')['output'])

    def test_traversal_and_symlink(self):
        with self.assertRaises(ReviewError):
            self.store.sample('../outside')
        path = self.directory / 'sample-demo/blind/clip-0001.wav'
        path.unlink()
        path.symlink_to(ROOT / 'AGENTS.md')
        with self.assertRaises(ReviewError):
            self.store.audio('sample-demo', 'clip-0001')

    def test_http_guards_and_audio_ranges(self):
        server = make_server(self.directory, 0)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        port = server.server_address[1]
        def request(method, path, body=None, headers=None):
            connection = http.client.HTTPConnection('127.0.0.1', port, timeout=3)
            connection.request(method, path, body, headers or {})
            response = connection.getresponse()
            value = response.read()
            connection.close()
            return response.status, value
        try:
            self.assertEqual(request('GET', '/api/samples')[0], 200)
            navigation = {'Sec-Fetch-Site': 'cross-site', 'Sec-Fetch-Dest': 'document'}
            self.assertEqual(request('GET', '/', headers=navigation)[0], 200)
            self.assertEqual(request('GET', '/api/samples', headers=navigation)[0], 403)
            self.assertEqual(request('GET', '/api/audio/sample-demo/clip-0001', headers=navigation)[0], 403)
            self.assertEqual(request('GET', '/api/samples', headers={'Host': 'example.test'})[0], 403)
            self.assertEqual(request('PUT', '/api/samples/sample-demo', '{}', {'Origin': 'http://example.test', 'Content-Type': 'application/json'})[0], 403)
            status, audio = request('GET', '/api/audio/sample-demo/clip-0001', headers={'Range': 'bytes=0-3'})
            self.assertEqual((status, audio), (206, b'RIFF'))
            self.assertEqual(request('GET', '/api/audio/sample-demo/clip-0001', headers={'Range': 'bytes=999999-'})[0], 416)
            self.assertEqual(request('GET', '/api/audio/sample-demo/clip-0001', headers={'Range': 'bytes=0-1,5-6'})[0], 416)
            self.assertEqual(request('GET', '/sample-demo/private/key.json')[0], 404)
            self.assertEqual(request('PUT', '/api/samples/sample-demo', '{}', {'Content-Type': 'text/plain'})[0], 400)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == '__main__':
    unittest.main()
