"""Synthetic checks for complete coverage, recovery, and stale extraction data."""
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import numpy as np

from model_extract import atomic_json, digest, extract, frames, prepare


class ExtractionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / 'source.bin'
        self.source.write_bytes(b'synthetic recording')
        self.pcm = self.root / 'audio.f32'
        np.linspace(-.2, .2, 2048, dtype='<f4').tofile(self.pcm)
        self.original = self.root / 'input.json'
        self.original.write_text('{}')
        self.module_path = self.root / 'synthetic_adapter.py'
        self.module_path.write_text('# synthetic module\n')
        self.config = self.root / 'config.json'
        self.config.write_text(json.dumps(dict(module='synthetic_adapter', kwargs={})))
        self.prepared = self.root / 'prepared.json'
        source = str(self.source)
        track = dict(source=source, source_sha256=digest(self.source), pcm_path=str(self.pcm),
                     pcm_sha256=digest(self.pcm), decoded_samples=2048)
        self.document = dict(provenance=dict(input_path=str(self.original), input_sha256=digest(self.original)),
            tracks={source: track}, jobs=[dict(key='a', source=source, bounds=[[0,512]], sample_count=512),
                                          dict(key='b', source=source, bounds=[[512,1024]], sample_count=512)],
            aliases=[dict(id='first',key='a'),dict(id='second',key='b'),dict(id='alias',key='a')])
        atomic_json(self.prepared, self.document)
        self.output = self.root / 'results'
        self.calls = []
        self.adapter = SimpleNamespace(metadata=dict(model_id='synthetic',embedding_dimension=2), device='cpu',
                                       embed_batch=self.embed)
        self.module = SimpleNamespace(__file__=str(self.module_path), load_model=lambda **kwargs:self.adapter)
        self.importer = patch('model_extract.importlib.import_module',return_value=self.module)
        self.importer.start()
        self.addCleanup(self.importer.stop)

    def embed(self, audio):
        self.calls.append(audio.copy())
        return np.stack([audio.mean(axis=1),np.ones(len(audio))],axis=1)

    def run_extract(self, **kwargs):
        return extract(self.prepared,self.output,self.config,**kwargs)

    def test_complete_output_preserves_alias_and_resumes_without_inference(self):
        summary = self.run_extract(batch_size=2)
        self.assertTrue(summary['complete'])
        with np.load(self.output/'embeddings.npz') as result:
            self.assertEqual(result['ids'].tolist(),['first','second','alias'])
            np.testing.assert_array_equal(result['embeddings'][0],result['embeddings'][2])
            np.testing.assert_allclose(np.linalg.norm(result['embeddings'],axis=1),1,atol=1e-7)
        self.assertEqual(len(self.calls),1)
        self.run_extract(batch_size=2)
        self.assertEqual(len(self.calls),1)

    def test_failure_retains_prior_batch_and_retry_finishes(self):
        def failing(audio):
            if self.calls:
                raise RuntimeError('synthetic failure')
            return self.embed(audio)
        self.adapter.embed_batch = failing
        with self.assertRaisesRegex(RuntimeError,'synthetic failure'):
            self.run_extract(batch_size=1)
        self.assertFalse((self.output/'embeddings.npz').exists())
        self.assertEqual(len(list((self.output/'checkpoints').glob('*.json'))),1)
        self.adapter.embed_batch = self.embed
        self.run_extract(batch_size=1)
        self.assertEqual(len(self.calls),2)

    def test_benchmark_is_capped_and_cannot_publish_complete_output(self):
        summary = self.run_extract(batch_size=8,limit=1)
        self.assertFalse(summary['complete'])
        self.assertEqual(summary['unique_jobs'],1)
        self.assertFalse((self.output/'embeddings.npz').exists())

    def test_changed_audio_adapter_and_checkpoint_fail_closed(self):
        self.run_extract()
        self.module_path.write_text('# changed adapter\n')
        with self.assertRaisesRegex(ValueError,'changed'):
            self.run_extract()
        self.module_path.write_text('# synthetic module\n')
        checkpoint=next((self.output/'checkpoints').glob('*.npz'))
        checkpoint.write_bytes(b'changed checkpoint')
        with self.assertRaisesRegex(ValueError,'checkpoint changed'):
            self.run_extract()
        self.pcm.write_bytes(b'changed audio')
        with self.assertRaisesRegex(ValueError,'audio changed'):
            self.run_extract()

    def test_changed_original_input_and_nan_output_are_rejected(self):
        self.original.write_text('{"changed":true}')
        with self.assertRaisesRegex(ValueError,'input changed'):
            self.run_extract()
        self.original.write_text('{}')
        self.adapter.embed_batch=lambda audio:np.full((len(audio),2),np.nan)
        with self.assertRaisesRegex(ValueError,'invalid embedding'):
            self.run_extract()
        self.assertFalse((self.output/'embeddings.npz').exists())

    def test_unequal_lengths_are_separate_batches_without_padding(self):
        self.document['jobs'][1].update(bounds=[[512,1536]],sample_count=1024)
        atomic_json(self.prepared,self.document)
        self.run_extract(batch_size=8)
        self.assertEqual([value.shape for value in self.calls],[(1,512),(1,1024)])


class PreparationTests(unittest.TestCase):
    def test_frame_bounds_reject_clipping_and_overlap(self):
        self.assertEqual(frames([dict(start=0,end=.032)],512),[[0,512]])
        for spans in [[dict(start=0,end=1)], [dict(start=0,end=.02),dict(start=.01,end=.03)]]:
            with self.assertRaises(ValueError):
                frames(spans,512)

    def test_decode_frame_mismatch_cannot_publish_manifest(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            source=root/'library/meetings/synthetic/audio.wav'
            source.parent.mkdir(parents=True)
            source.write_bytes(b'synthetic')
            inventory=dict(meetings=[dict(id='meeting',folder='synthetic')],samples=[],examples=[])
            input_path=root/'input.json'
            atomic_json(input_path,inventory)
            atomic_json(root/'full-speech-manifest.json',dict(summary=dict(complete=True),recordings=[dict(
                status='complete',meeting_id='meeting',audio_file='audio.wav',audio_sha256=digest(source),decoded_samples=1000)]))
            def run(command,**kwargs):
                if command==['ffmpeg','-version']:
                    return SimpleNamespace(stdout='ffmpeg synthetic\n')
                Path(command[-1]).write_bytes(b'\0'*100)
            with patch('model_extract.subprocess.run',side_effect=run),self.assertRaisesRegex(ValueError,'frame count'):
                prepare(input_path,root/'prepared')
            self.assertFalse((root/'prepared/prepared.json').exists())


if __name__ == '__main__':
    unittest.main()
