"""Synthetic checks for common observations, graph caps, and arrival sweeps."""
import json
import math
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import numpy as np

import model_compare as models
from full_compare import cluster, representatives, full_metrics


def fixture(count=3):
    samples = [dict(id=f'window-{i}', example_id=f'window-{i}', meeting_id=f'm{i%2}',
        meeting_order=i%2, model='old', eligible=True, density_key=f'physical-{i}',
        embedding=[math.cos(i*.6),math.sin(i*.6)],audio_path='synthetic.wav',
        support_spans=[dict(start=i*3,end=i*3+2)],embedding_spans=[dict(start=i*3,end=i*3+2)])
        for i in range(count)]
    return dict(samples=samples,examples=[dict(id=s['id']) for s in samples],
                meetings=[dict(id=f'm{i}',meeting_order=i) for i in range(2)])


class ModelComparisonTests(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root=Path(self.temporary.name).resolve()
        self.source=fixture()
        self.path=self.root/'embeddings.npz'
        self.summary=self.root/'summary.json'
        self.summary.write_text(json.dumps(dict(complete=True,benchmark=False,expected_rows=3,unique_jobs=3,
                                                expected_unique_jobs=3,model_metadata=dict(model_id='synthetic',embedding_dimension=2))))
        self.original=self.root/'input.json'
        self.audio=self.root/'synthetic.wav'
        self.audio.write_bytes(b'synthetic recording')
        for sample in self.source['samples']:
            sample['audio_revision']=models.digest(self.audio)
        self.original.write_text(json.dumps(self.source))
        self.prepared=self.root/'prepared.json'
        self.provenance=self.root/'extraction-provenance.json'
        self.plan=dict(provenance=dict(input_path=str(self.original),input_sha256=models.digest(self.original)),
            tracks={str(self.audio):dict(source_sha256=models.digest(self.audio),decoded_samples=128000)},
            aliases=[dict(id=s['id'],key=s['density_key'],embedding_spans=s['embedding_spans'],support_spans=s['support_spans']) for s in self.source['samples']],
            jobs=[dict(key=s['density_key'],source=str(self.audio),bounds=models.frames(s['embedding_spans'],128000),sample_count=32000) for s in self.source['samples']])
        self.save_plan()
        self.entry=dict(id='global_dbscan_synthetic',label='Synthetic',embeddings=str(self.path),summary=str(self.summary),
                        prepared=str(self.prepared),provenance=str(self.provenance),expected_model_id='synthetic')
        self.write_vectors()

    def save_plan(self):
        self.prepared.write_text(json.dumps(self.plan))
        self.provenance.write_text(json.dumps(dict(prepared_sha256=models.digest(self.prepared),
            model_metadata=dict(model_id='synthetic',embedding_dimension=2))))

    def write_vectors(self,ids=None,vectors=None):
        np.savez_compressed(self.path,ids=np.asarray(ids or [s['id'] for s in self.source['samples']]),
                            embeddings=np.asarray(vectors if vectors is not None else [s['embedding'] for s in self.source['samples']]),
                            model_id=np.asarray('synthetic'))

    def test_npz_order_does_not_change_observation_identity(self):
        self.write_vectors(ids=['window-2','window-0','window-1'],vectors=[[0,2],[3,0],[1,1]])
        samples=models.load_samples(self.source,self.path,self.entry['id'])
        self.assertEqual([s['id'] for s in samples],['window-0','window-1','window-2'])
        self.assertEqual(samples[0]['embedding'],[1,0])
        self.assertEqual(samples[2]['embedding'],[0,1])
        self.assertTrue(all(s['model']==self.entry['id'] for s in samples))
        self.assertEqual(self.source['samples'][0]['model'],'old')

    def test_missing_duplicate_nonfinite_zero_and_malformed_vectors_are_rejected(self):
        cases=[(['window-0','window-1'],[[1,0],[1,0]]),
               (['window-0','window-0','window-2'],[[1,0]]*3),
               (None,[[float('nan'),1],[1,0],[1,0]]),
               (None,[[0,0],[1,0],[1,0]]),
               (None,[1,2,3])]
        for ids,vectors in cases:
            with self.subTest(ids=ids,vectors=vectors):
                self.write_vectors(ids,vectors)
                with self.assertRaises(ValueError):
                    models.load_samples(self.source,self.path,self.entry['id'])

    def test_graph_cap_skips_dense_low_thresholds_and_keeps_default_and_variants(self):
        default,catalog,arrivals=models.evaluate(self.source,self.entry,self.root/'out',max_edges=7)
        self.assertEqual(catalog['skipped_settings'][0]['similarity'],.35)
        self.assertEqual(default['variant'],'s080_m3')
        self.assertEqual(len(default['assignments']),3)
        self.assertEqual(catalog['neighbor_edges'],7)
        self.assertEqual(len(catalog['variants']),(len(models.THRESHOLDS)-1)*2)
        for variant in catalog['variants']:
            path=self.root/'out'/variant['path']
            value=json.loads(path.read_text())
            self.assertEqual(set(value['assignments']),{s['id'] for s in self.source['samples']})
            self.assertEqual(models.digest(path),variant['sha256'])
            self.assertEqual(value['policy']['similarity'],variant['similarity'])

    def test_default_resource_failure_publishes_no_variants(self):
        destination=self.root/'out'
        with self.assertRaisesRegex(ValueError,'default setting'):
            models.evaluate(self.source,self.entry,destination,max_edges=3)
        self.assertFalse(list(destination.rglob('*.json')))

    def test_graph_values_are_symmetric_and_count_self_neighbors(self):
        graph=models.graph_at(self.source['samples'],.8,max_edges=20,block_size=1)
        np.testing.assert_allclose(graph.toarray(),graph.toarray().T)
        np.testing.assert_allclose(graph.diagonal(),1)
        self.assertEqual(graph.nnz,7)

    def test_incomplete_benchmark_or_wrong_count_summary_is_rejected(self):
        original=json.loads(self.summary.read_text())
        for field,value in [('complete',False),('benchmark',True),('expected_rows',2),('unique_jobs',2)]:
            self.summary.write_text(json.dumps({**original,field:value}))
            with self.subTest(field=field),self.assertRaisesRegex(ValueError,'complete'):
                models.validate_run(self.source,self.entry)
        self.summary.write_text(json.dumps(original))

    def test_original_enriched_embeddings_are_required_for_review_coverage(self):
        for embedding in [None,[],[0,0],[float('nan'),1],[float('inf'),1]]:
            source=json.loads(json.dumps(self.source))
            if embedding is None:
                source['samples'][0].pop('embedding')
            else:
                source['samples'][0]['embedding']=embedding
            self.original.write_text(json.dumps(source))
            self.plan['provenance']['input_sha256']=models.digest(self.original)
            self.save_plan()
            with self.subTest(embedding=embedding),self.assertRaisesRegex(ValueError,'finite nonzero original embeddings'):
                models.validate_run(source,self.entry)

    def test_npz_and_receipt_model_identity_must_match(self):
        with self.assertRaisesRegex(ValueError,'Descriptor model identity'):
            models.validate_run(self.source,{**self.entry,'expected_model_id':'swapped-model'})
        with self.assertRaisesRegex(ValueError,'Descriptor model identity'):
            models.validate_run(self.source,{key:value for key,value in self.entry.items() if key!='expected_model_id'})
        with np.load(self.path) as data:
            ids,vectors=data['ids'],data['embeddings']
        np.savez_compressed(self.path,ids=ids,embeddings=vectors,model_id=np.asarray('different-model'))
        with self.assertRaisesRegex(ValueError,'model identity'):
            models.validate_run(self.source,self.entry)
        self.write_vectors()
        provenance=json.loads(self.provenance.read_text())
        provenance['model_metadata']['model_id']='different-model'
        self.provenance.write_text(json.dumps(provenance))
        with self.assertRaisesRegex(ValueError,'Model identity'):
            models.validate_run(self.source,self.entry)

    def test_stale_input_plan_and_altered_window_evidence_are_rejected(self):
        summary,receipt=models.validate_run(self.source,self.entry,models.digest(self.original))
        self.assertTrue(summary['complete'])
        self.assertEqual(receipt['prepared_sha256'],models.digest(self.prepared))
        with self.assertRaisesRegex(ValueError,'different full-speech input'):
            models.validate_run(self.source,self.entry,'different-input-hash')
        self.plan['aliases'][0]['support_spans']=[dict(start=.1,end=.2)]
        self.prepared.write_text(json.dumps(self.plan))
        with self.assertRaisesRegex(ValueError,'provenance'):
            models.validate_run(self.source,self.entry)
        self.save_plan()
        with self.assertRaisesRegex(ValueError,'window support'):
            models.validate_run(self.source,self.entry)

    def test_duplicate_observation_ids_and_changed_frame_bounds_are_rejected(self):
        self.plan['jobs'][0]['bounds']=[[1,32001]]
        self.save_plan()
        with self.assertRaisesRegex(ValueError,'sample bounds'):
            models.validate_run(self.source,self.entry)
        source=fixture()
        source['samples'][1]['id']=source['samples'][0]['id']
        with self.assertRaisesRegex(ValueError,'same speech observations'):
            models.load_samples(source,self.path,'typed-model')

    def test_cli_rejects_different_canonical_plans_before_writing_variants(self):
        self.source['metadata']=dict(full_speech=dict(windows=3,excluded_windows=0,complete=True))
        self.original.write_text(json.dumps(self.source))
        self.plan['provenance']['input_sha256']=models.digest(self.original)
        self.save_plan()
        second_plan=json.loads(self.prepared.read_text())
        second_plan['tracks'][str(self.audio)]['pcm_sha256']='different canonical audio'
        alternate=self.root/'alternate-prepared.json'
        alternate.write_text(json.dumps(second_plan))
        alternate_receipt=self.root/'alternate-provenance.json'
        receipt=json.loads(self.provenance.read_text())
        receipt['prepared_sha256']=models.digest(alternate)
        alternate_receipt.write_text(json.dumps(receipt))
        entries=[self.entry,{**self.entry,'id':'global_dbscan_second','prepared':str(alternate),
                             'provenance':str(alternate_receipt)}]
        manifest=self.root/'models.json'
        manifest.write_text(json.dumps(entries))
        baseline=self.root/'baseline.json'
        baseline.write_text(json.dumps(dict(samples=[],examples=[])))
        old=self.root/'baseline-results.json'
        old.write_text(json.dumps(dict(metadata=dict(input_sha256=models.digest(baseline)),methods={})))
        output=self.root/'out'
        argv=['model_compare.py','--input',str(self.original),'--baseline-input',str(baseline),
              '--baseline-results',str(old),'--models',str(manifest),'--output',str(output)]
        with patch('sys.argv',argv),self.assertRaisesRegex(ValueError,'same canonical audio'):
            models.main()
        self.assertFalse(output.exists())

    def test_changed_run_inputs_during_graph_work_cannot_finish_comparison(self):
        graph_at=models.graph_at
        def changing(*args,**kwargs):
            self.summary.write_text(self.summary.read_text()+' ')
            return graph_at(*args,**kwargs)
        with patch('model_compare.graph_at',side_effect=changing),self.assertRaisesRegex(ValueError,'changed during comparison'):
            models.evaluate(self.source,self.entry,self.root/'out',max_edges=20)

    def test_arrivals_keep_future_aliases_out_and_finish_at_full_default(self):
        source=fixture(12)
        for i,sample in enumerate(source['samples']):
            sample['embedding']=[1,0]
            if i<2:
                sample['density_key']='same'
                sample['embedding_spans']=[dict(start=0,end=2)]
                sample['support_spans']=[dict(start=0,end=2)]
        samples=sorted(source['samples'],key=lambda s:s['id'])
        indices,members=representatives(samples)
        graph=models.graph_at([samples[i] for i in indices],.35,max_edges=200)
        full=full_metrics(cluster(samples,indices,members,graph))
        for scenario in models.arrivals(source,samples,indices,members,graph):
            self.assertEqual(scenario['checkpoints'][-1]['metrics'],full)
            for checkpoint in scenario['checkpoints']:
                self.assertEqual(checkpoint['metrics']['samples'],checkpoint['samples'])
        growing=next(s for s in models.arrivals(source,samples,indices,members,graph) if s['name']=='growing_samples')
        self.assertEqual([c['samples'] for c in growing['checkpoints']],[2,4,6,8,10,12])


if __name__=='__main__':
    unittest.main()
