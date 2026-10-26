"""Synthetic HDBSCAN density, quality, arrival, and provenance regressions."""
import copy
import json
import math
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import numpy as np

import hdbscan_compare as comparison
from compare import assign_groups
from full_compare import representatives
from model_compare import digest


def samples_fixture(count=24):
    samples=[]
    for i in range(count):
        angle=(i//8)*1.5+(i%8)*.008
        samples.append(dict(id=f'window-{i:03}',example_id=f'window-{i:03}',density_key=f'physical-{i:03}',
            eligible=True,model='synthetic',embedding=[math.cos(angle),math.sin(angle)],
            meeting_id=f'm{i%2}',meeting_order=i%2,audio_path='synthetic.wav',audio_revision='a'*64,
            support_spans=[dict(start=i*2,end=i*2+2)],embedding_spans=[dict(start=i*2,end=i*2+2)]))
    return samples


class AlgorithmTests(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root=Path(self.temporary.name).resolve()

    def test_installed_contrib_min_samples_excludes_self(self):
        import hdbscan
        values=np.array([[0.],[1.],[4.],[10.]])
        model=hdbscan.HDBSCAN(min_cluster_size=2,min_samples=2,algorithm='prims_kdtree',
            approx_min_span_tree=False,gen_min_span_tree=True,core_dist_n_jobs=1).fit(values)
        np.testing.assert_allclose(sorted(model.minimum_spanning_tree_.to_numpy()[:,2]),[4,4,9])
        # Including self would instead produce core/MST edge distances [1,3,6].
        self.assertEqual(comparison.policy_for('all','eom',5,3)['contrib_min_samples'],2)

    def test_exact_generic_and_prims_backends_agree_on_nondegenerate_vectors(self):
        from sklearn.metrics import adjusted_rand_score
        rng=np.random.default_rng(7)
        centers=rng.normal(size=(3,16))
        values=centers[np.arange(30)%3]+rng.normal(0,.07,size=(30,16))
        values=np.ascontiguousarray(values/np.linalg.norm(values,axis=1,keepdims=True))
        for selection in ('eom','leaf'):
            generic=comparison.hdbscan_fit(values,selection,5,3,self.root/'generic','generic')
            prims=comparison.hdbscan_fit(values,selection,5,3,self.root/'prims','prims_kdtree')
            self.assertEqual(adjusted_rand_score(generic['labels'],prims['labels']),1)
            np.testing.assert_array_equal(generic['labels']<0,prims['labels']<0)
            np.testing.assert_allclose(generic['probabilities'],prims['probabilities'],atol=1e-12)

    def test_dense_working_budget_fails_before_fit_and_explicit_prims_bypasses_it(self):
        values=np.array([sample['embedding'] for sample in samples_fixture()])
        expected=3*len(values)**2*8+2*values.nbytes
        self.assertEqual(comparison.dense_working_estimate(values),expected)
        with self.assertRaisesRegex(ValueError,'working estimate exceeds'):
            comparison.hdbscan_fit(values,'eom',5,3,self.root,'generic',max_dense_bytes=expected-1)
        result=comparison.hdbscan_fit(values,'eom',5,3,self.root,'prims_kdtree',max_dense_bytes=1)
        self.assertEqual(result['mst_backend'],'prims_kdtree')
        self.assertEqual(result['dense_working_estimate_bytes'],0)

    def test_nonoverlap_selection_maximizes_support_and_uses_source_hash(self):
        samples=samples_fixture(4)
        for sample,bounds in zip(samples,[(0,4),(0,2),(2,4),(4,6)]):
            sample['embedding_spans']=[dict(start=bounds[0],end=bounds[1])]
        indices,_=representatives(samples)
        self.assertEqual(comparison.nonoverlapping_positions(samples,indices),[1,2,3])
        changed=copy.deepcopy(samples)
        for sample in changed:
            sample['person_id']='unrelated-person'
        self.assertEqual(comparison.nonoverlapping_positions(changed,indices),[1,2,3])
        samples[0]['audio_revision']='b'*64
        self.assertEqual(comparison.nonoverlapping_positions(samples,indices),[0,1,2,3])

    def test_all_ids_aliases_and_nonoverlap_omissions_remain_distinct_from_noise(self):
        samples=samples_fixture(12)
        samples[1]['embedding_spans']=[dict(start=0,end=2)]
        alias={**copy.deepcopy(samples[0]),'id':'window-alias','example_id':'window-alias'}
        samples.append(alias)
        assignments,metrics,indices,_,_=comparison.fit_case(samples,comparison.policy_for('nonoverlap','eom',5,3),self.root,10000)
        self.assertEqual(set(assignments),{sample['id'] for sample in samples})
        omitted=assignments[samples[1]['id']]
        self.assertEqual(omitted['fit_role'],'overlap_omitted')
        self.assertEqual(omitted['state'],'excluded')
        self.assertIsNone(omitted['noise'])
        self.assertIsNone(omitted['membership_confidence'])
        self.assertEqual(assignments[alias['id']]['group'],assignments[samples[0]['id']]['group'])
        self.assertEqual(metrics['physical_observations'],12)
        self.assertEqual(metrics['omitted_physical_observations'],1)
        self.assertEqual(metrics['omitted_samples'],1)
        self.assertIsNone(metrics['core_samples'])

    def test_eom_leaf_and_distance_metadata_are_explicit(self):
        samples=samples_fixture()
        for selection in ('eom','leaf'):
            policy=comparison.policy_for('all',selection,5,3)
            assignments,metrics,_,_,_=comparison.fit_case(samples,policy,self.root,10000)
            self.assertEqual(metrics['samples'],24)
            self.assertGreaterEqual(metrics['non_singleton_groups'],2)
            self.assertTrue(all(row['fit_role']=='fitted' for row in assignments.values()))
            for row in assignments.values():
                self.assertGreaterEqual(row['membership_confidence'],0)
                self.assertLessEqual(row['membership_confidence'],1)
            self.assertEqual(policy['distance'],'euclidean_on_unit_l2')
        vectors=np.array([sample['embedding'] for sample in samples])
        np.testing.assert_allclose(np.linalg.norm(vectors[0]-vectors[10])**2,2*(1-vectors[0]@vectors[10]),atol=1e-12)

    def test_matched_dbscan_matches_stock_vector_fit(self):
        from sklearn.cluster import DBSCAN
        samples=samples_fixture()
        samples[1]['embedding_spans']=[dict(start=0,end=2)]
        policy=comparison.policy_for('nonoverlap',density=3,similarity=.8)
        assignments,metrics,indices,_,_=comparison.fit_case(samples,policy,self.root,10000)
        positions=comparison.nonoverlapping_positions(samples,indices)
        vectors=np.array([samples[indices[i]]['embedding'] for i in positions])
        expected=DBSCAN(eps=math.sqrt(.4)+1e-12,min_samples=3).fit_predict(vectors)
        for a in range(len(positions)):
            for b in range(a+1,len(positions)):
                row_a=assignments[samples[indices[positions[a]]]['id']]
                row_b=assignments[samples[indices[positions[b]]]['id']]
                self.assertEqual(row_a['group']==row_b['group'],expected[a]>=0 and expected[a]==expected[b])
        self.assertEqual(metrics['omitted_samples'],1)
        self.assertEqual(metrics['noise_samples'],int(np.sum(expected<0)))

    def test_quality_pair_counts_separate_merges_splits_noise_and_omissions(self):
        samples=samples_fixture(5)
        indices,members=representatives(samples)
        labels={sample['id']:person for sample,person in zip(samples,['a','a','b','b','c'])}
        assignments={sample['id']:dict(group=group,fit_role=role,noise=noise) for sample,group,role,noise in zip(
            samples,['joined','split','joined','noise','omitted'],['fitted']*4+['overlap_omitted'],[False,False,False,True,None])}
        result=comparison.quality_for(samples,indices,members,assignments,labels)
        self.assertEqual(result['labeled_physical_observations'],4)
        self.assertEqual(result['false_merge_pairs'],1)
        self.assertEqual(result['false_split_cluster_pairs'],1)
        self.assertEqual(result['same_person_unresolved_pairs'],1)
        self.assertEqual(result['missed_same_person_pairs'],2)
        self.assertEqual(result['pair_precision'],0)
        self.assertEqual(comparison.quality_for(samples,indices,members,assignments,{})['status'],'unavailable')

    def test_conflicting_alias_identity_judgments_are_rejected(self):
        samples=samples_fixture(2)
        samples[1]=dict(samples[0],id='alias')
        indices,members=representatives(samples)
        with self.assertRaisesRegex(ValueError,'identical physical support'):
            comparison.quality_for(samples,indices,members,{},dict([(samples[0]['id'],'a'),('alias','b')]))

    def test_arrivals_count_physical_support_even_when_representative_alias_changes(self):
        samples=samples_fixture(12)
        # The later speech support makes the lexically earlier alias arrive later.
        later=copy.deepcopy(samples[0])
        later.update(id='a-future-alias',example_id='a-future-alias',support_spans=[dict(start=.5,end=1.5)])
        samples.append(later)
        samples.sort(key=lambda sample:sample['id'])
        source=dict(meetings=[dict(id='m0',meeting_order=0),dict(id='m1',meeting_order=1)])
        policy=comparison.policy_for('all','leaf',5,3)
        full,metrics,*_=comparison.fit_case(samples,policy,self.root,10000)
        scenarios=comparison.arrival_results(source,samples,'method','leaf',policy,self.root,10000,(full,metrics))
        for scenario in scenarios:
            self.assertEqual(scenario['checkpoints'][-1]['metrics'],metrics)
        growing=next(s for s in scenarios if s['name']=='growing_samples')
        self.assertEqual(growing['checkpoints'][1]['change']['shared_samples'],1)

    def test_churn_ignores_cluster_label_changes_and_counts_noise_transitions(self):
        before={'a':dict(group='old',person_id=None,noise=False,fit_role='fitted'),
                'b':dict(group='old',person_id=None,noise=False,fit_role='fitted')}
        after={key:{**row,'group':'renamed'} for key,row in before.items()}
        self.assertEqual(comparison.churn(before,after)['co_membership_changed_pairs'],0)
        after['b'].update(noise=True,group='isolated')
        result=comparison.churn(before,after)
        self.assertEqual(result['clustered_to_noise'],1)
        self.assertEqual(result['co_membership_changed_pairs'],1)


class BundleTests(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root=Path(self.temporary.name).resolve()
        self.source=self.root/'input.json'
        self.samples=samples_fixture()
        self.audio=self.root/'synthetic.wav'
        self.audio.write_bytes(b'synthetic')
        for sample in self.samples:
            sample['audio_revision']=digest(self.audio)
        self.document=dict(samples=self.samples,examples=[dict(id=sample['id']) for sample in self.samples],
            meetings=[dict(id='m0',meeting_order=0),dict(id='m1',meeting_order=1)],
            metadata=dict(full_speech=dict(complete=True,windows=24,excluded_windows=0)))
        self.source.write_text(json.dumps(self.document))
        self.prepared=self.root/'prepared.json'
        plan=dict(provenance=dict(input_path=str(self.source),input_sha256=digest(self.source)),
            tracks={str(self.audio):dict(source_sha256=digest(self.audio),decoded_samples=24*32000)},
            aliases=[dict(id=s['id'],key=s['density_key'],support_spans=s['support_spans'],embedding_spans=s['embedding_spans']) for s in self.samples],
            jobs=[dict(key=s['density_key'],source=str(self.audio),bounds=[[i*32000,(i+1)*32000]],sample_count=32000) for i,s in enumerate(self.samples)])
        self.prepared.write_text(json.dumps(plan))
        self.entries=[]
        for key,model_id in comparison.MODEL_IDS.items():
            run=self.root/key
            run.mkdir()
            metadata=dict(model_id=model_id,embedding_dimension=2)
            embeddings=run/'embeddings.npz'
            np.savez_compressed(embeddings,ids=np.array([sample['id'] for sample in self.samples]),
                                embeddings=np.array([sample['embedding'] for sample in self.samples]),model_id=np.asarray(model_id))
            summary=run/'summary.json'
            summary.write_text(json.dumps(dict(complete=True,benchmark=False,expected_rows=24,unique_jobs=24,expected_unique_jobs=24,model_metadata=metadata)))
            provenance=run/'extraction-provenance.json'
            provenance.write_text(json.dumps(dict(prepared_sha256=digest(self.prepared),model_metadata=metadata)))
            self.entries.append(dict(id='global_dbscan_'+key,model_key=key,label=key,expected_model_id=model_id,
                embeddings=str(embeddings),summary=str(summary),prepared=str(self.prepared),provenance=str(provenance)))
        self.manifest=self.root/'models.json'
        self.manifest.write_text(json.dumps(self.entries))
        self.review=self.root/'review'
        self.review.mkdir()
        (self.review/'review-input.json').write_text(self.source.read_text())
        base=assign_groups(self.samples,[[i] for i in range(24)],'reference',cold=True)
        catalog=[]
        for entry in self.entries:
            summary,provenance=comparison.validate_run(self.document,entry,digest(self.source))
            catalog.append(dict(id=entry['id'],embeddings_sha256=digest(entry['embeddings']),
                                provenance=provenance,embedding_metadata=summary))
        result=dict(metadata=dict(input_sha256=digest(self.review/'review-input.json'),full_speech_input_sha256=digest(self.source)),
            methods={entry['id']:dict(assignments=base) for entry in self.entries},
            method_catalog=catalog,scenarios=[])
        (self.review/'results.json').write_text(json.dumps(result))
        self.output=self.root/'hdbscan'
        self.patches=[patch.object(comparison,'CLUSTER_SIZES',(5,)),patch.object(comparison,'DENSITIES',(3,)),patch.object(comparison,'SIMILARITIES',(.8,)),patch('builtins.print')]
        for current in self.patches:
            current.start()
            self.addCleanup(current.stop)

    def run_model(self,key,benchmark=False):
        return comparison.run_model(self.source,self.manifest,key,self.output,benchmark=benchmark)

    def test_complete_five_model_bundle_keeps_both_selections_and_all_ids(self):
        for key in comparison.MODEL_IDS:
            result=self.run_model(key)
            self.assertEqual(result['status'],'complete')
            self.assertEqual(len(result['method_catalog']),3)
            self.assertEqual(len(result['scenarios']),10)
            for method in result['methods'].values():
                self.assertEqual(set(method['assignments']),{sample['id'] for sample in self.samples})
        combined=comparison.attach(self.source,self.manifest,self.output,self.review)
        self.assertEqual(combined['metadata']['hdbscan_comparison']['models'],5)
        self.assertEqual(len(combined['methods']),20)
        first=combined['scenarios'][0]['checkpoints'][-1]
        variants=first['variant_methods']['global_hdbscan_wespeaker']
        self.assertEqual(set(variants),{'all_eom_c005_m003','all_leaf_c005_m003'})
        for item in combined['method_catalog']:
            for variant in item.get('variants',[]):
                self.assertEqual(digest(self.review/variant['path']),variant['sha256'])
        again=comparison.attach(self.source,self.manifest,self.output,self.review)
        self.assertEqual(len(again['method_catalog']),20)

    def test_later_invalid_variant_prevents_any_attachment_copy(self):
        for key in comparison.MODEL_IDS:
            self.run_model(key)
        path=self.output/'model-results/campplus.json'
        run=json.loads(path.read_text())
        variant=run['method_catalog'][-1]['variants'][-1]
        (self.output/variant['path']).write_text('changed variant')
        original=(self.review/'results.json').read_bytes()
        with self.assertRaisesRegex(ValueError,'Clustering variant changed'):
            comparison.attach(self.source,self.manifest,self.output,self.review)
        self.assertFalse((self.review/'variants').exists())
        self.assertEqual((self.review/'results.json').read_bytes(),original)

    def test_corrected_variant_cannot_overwrite_existing_review_artifact(self):
        for key in comparison.MODEL_IDS:
            self.run_model(key)
        comparison.attach(self.source,self.manifest,self.output,self.review)
        path=self.output/'model-results/wespeaker.json'
        run=json.loads(path.read_text())
        variant=run['method_catalog'][0]['variants'][0]
        source=self.output/variant['path']
        value=json.loads(source.read_text())
        value['description']='Corrected synthetic description'
        source.write_text(json.dumps(value))
        variant['sha256']=digest(source)
        run['methods'][run['method_catalog'][0]['id']]=value
        path.write_text(json.dumps(run))
        original=(self.review/'results.json').read_bytes()
        destination=self.review/variant['path']
        old_variant=destination.read_bytes()
        with self.assertRaisesRegex(ValueError,'new review directory'):
            comparison.attach(self.source,self.manifest,self.output,self.review)
        self.assertEqual(destination.read_bytes(),old_variant)
        self.assertEqual((self.review/'results.json').read_bytes(),original)

    def test_benchmark_and_missing_models_cannot_attach_complete_bundle(self):
        self.run_model('wespeaker',benchmark=True)
        with self.assertRaisesRegex(ValueError,'incomplete or stale'):
            comparison.attach(self.source,self.manifest,self.output,self.review)
        self.assertNotIn('hdbscan_comparison',json.loads((self.review/'results.json').read_text())['metadata'])

    def test_existing_dbscan_embedding_identity_cannot_be_silently_replaced(self):
        original=json.loads((self.review/'results.json').read_text())
        original['method_catalog'][0]['embeddings_sha256']='different'
        (self.review/'results.json').write_text(json.dumps(original))
        with self.assertRaisesRegex(ValueError,'identical typed embeddings'):
            comparison.attach(self.source,self.manifest,self.output,self.review)

    def test_model_key_and_requested_identity_are_bound(self):
        entry={**self.entries[0],'expected_model_id':comparison.MODEL_IDS['redimnet_b6']}
        with self.assertRaisesRegex(ValueError,'embedding identity'):
            comparison.model_key(entry)


if __name__=='__main__':
    unittest.main()
