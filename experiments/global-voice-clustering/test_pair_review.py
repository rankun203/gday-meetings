"""Synthetic checks for reusable listening evidence and unbiased control selection."""
import unittest
import json
from pathlib import Path
import tempfile
from unittest.mock import patch

import pair_review

from pair_review import candidate_pairs, current_projection, current_relation, make_queue, pair_id, passage_sources, relation, usable_pair


def sample(identifier, start=0, revision='audio', meeting='meeting'):
    return dict(id=identifier, density_key=identifier, audio_revision=revision, meeting_id=meeting,
                embedding_spans=[dict(start=start, end=start+2)], support_spans=[dict(start=start, end=start+2)])


class PairReviewTests(unittest.TestCase):
    def test_pair_identity_is_unordered_and_duplicate_contexts_are_not_questions(self):
        self.assertEqual(pair_id('a','b'),pair_id('b','a'))
        a,b=sample('a'),sample('b',1)
        self.assertFalse(usable_pair(a,b))
        b['embedding_spans']=[dict(start=2,end=4)]
        self.assertTrue(usable_pair(a,b))
        b['density_key']='a'
        self.assertFalse(usable_pair(a,b))

    def test_noise_is_abstention_and_overlap_omissions_are_distinct(self):
        a=dict(group='x',noise=False)
        self.assertEqual(relation(a,a),'same')
        self.assertEqual(relation(a,dict(group='y',noise=False)),'different')
        self.assertEqual(relation(a,dict(group='x',noise=True)),'unresolved')
        self.assertEqual(relation(a,dict(group='x',fit_role='overlap_omitted')),'omitted')

    def test_aliases_do_not_repeat_the_same_physical_pair(self):
        a, alias, b = sample('a'), sample('alias'), sample('b', 3)
        alias['density_key'] = a['density_key']
        assignments = {'model':{s['id']:dict(group='group',noise=False) for s in (a,alias,b)}}
        self.assertEqual(set(candidate_pairs([a,alias,b],assignments,[])),{('a','b')})

    def test_current_projection_requires_unanimous_complete_physical_coverage(self):
        samples=[sample('a')]
        row=dict(coverage_intervals=[dict(sample_id='a',start=5,end=7)],recording_offset=5,
                 saved_person_id=None,saved_person_coverage='none',local_label='speaker_a')
        values=current_projection(samples,[row])
        self.assertEqual(values['a']['local'],'speaker_a')
        row['coverage_intervals'][0]['end']=6
        self.assertNotIn('a',current_projection(samples,[row]))
        row['coverage_intervals'][0]['end']=7
        row['has_unattributed_words']=True
        self.assertNotIn('a',current_projection(samples,[row]))

    def test_local_labels_cannot_establish_cross_meeting_identity(self):
        a=dict(meeting='one',local='speaker_a',speaker='speaker_a',scope='track_a',person=None)
        b=dict(meeting='two',local='speaker_a',speaker='speaker_a',scope='track_a',person=None)
        self.assertEqual(current_relation(a,b),'unresolved')
        b['meeting']='one'
        self.assertEqual(current_relation(a,b),'same')
        b['scope']='track_b'
        self.assertEqual(current_relation(a,b),'unresolved')
        b['scope']='track_a'
        b['local']='speaker_b'
        b['speaker']='speaker_b'
        self.assertEqual(current_relation(a,b),'different')
        a['person']=b['person']='person_a'
        b['meeting']='two'
        self.assertEqual(current_relation(a,b),'same')

    def test_existing_corrections_are_linked_only_for_complete_sample_support(self):
        rows=[dict(id='passage',coverage_intervals=[dict(sample_id='a',start=4,end=6)],recording_offset=4)]
        self.assertEqual(passage_sources([sample('a')],rows),{'a':['passage']})
        rows[0]['coverage_intervals'][0]['end']=5
        self.assertEqual(passage_sources([sample('a')],rows),{})

    def test_queue_reuses_pairs_across_configs_and_keeps_seeded_controls(self):
        samples=[sample(str(i),i*3) for i in range(20)]
        configs=[dict(id='current',primary=True),dict(id='a',primary=True),dict(id='b',primary=True)]
        assignments={'a':{s['id']:dict(group='x',noise=False) for s in samples},
                     'b':{s['id']:dict(group=s['id'],noise=False) for s in samples}}
        candidates={(str(i),str(i+1)):{'Group membership'} for i in range(19)}
        queue=make_queue(samples,configs,assignments,{},candidates,count=10)
        self.assertEqual(queue,make_queue(samples,configs,assignments,{},candidates,count=10))
        self.assertEqual(len(queue['pairs']),10)
        self.assertEqual(sum(p['selection']=='control' for p in queue['pairs']),2)
        self.assertEqual(len({p['id'] for p in queue['pairs']}),10)
        for pair in queue['pairs']:
            self.assertEqual(pair['predictions'],dict(current='unresolved',a='same',b='different'))
        self.assertEqual(len(make_queue(samples,configs,assignments,{},candidates,count=1)['pairs']),1)

    def test_unanimous_local_projection_rejects_conflicting_labels(self):
        rows=[dict(coverage_intervals=[dict(sample_id='a',start=i,end=i+1)],
                   local_label=str(i),saved_person_id=None,saved_person_coverage='none') for i in range(2)]
        values=current_projection([sample('a')],rows)
        self.assertIsNone(values['a']['local'])
        self.assertEqual(current_relation(values['a'],values['a']),'unresolved')

    def test_conflicting_saved_people_cannot_fall_back_to_one_local_speaker(self):
        rows=[dict(id=str(i),coverage_intervals=[dict(sample_id='a',start=i,end=i+1)],
                   local_label='speaker',speaker_id='local',recording_key='track',
                   saved_person_id=f'person-{i}',saved_person_coverage='full') for i in range(2)]
        self.assertNotIn('a',current_projection([sample('a')],rows))

    def test_changed_manifest_cannot_replace_existing_review(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            source=root/'review-input.json'
            source.write_text(json.dumps(dict(samples=[])))
            embeddings=root/'vectors.npz'
            embeddings.write_bytes(b'synthetic vectors; candidate construction is mocked')
            models=root/'models.json'
            models.write_text(json.dumps([dict(id=f'global_dbscan_m{i}',embeddings=str(embeddings)) for i in range(5)]))
            catalog=[dict(id=f'{algorithm}_m{i}',model_key=f'm{i}',algorithm=algorithm,
                          embeddings_sha256=pair_review.digest(embeddings))
                     for i in range(5) for algorithm in ('dbscan','hdbscan','hdbscan_nonoverlap','dbscan_nonoverlap')]
            for item in catalog:
                if item['algorithm']=='dbscan':
                    item['id']='global_'+item['id']
            result=root/'results.json'
            result.write_text(json.dumps(dict(metadata=dict(input_sha256=pair_review.digest(source),
                hdbscan_comparison=dict(models=5,models_manifest_sha256=pair_review.digest(models))),method_catalog=catalog)))
            before=result.read_bytes()
            def change_manifest(*args,**kwargs):
                models.write_text('[]')
                return {}
            with patch('sys.argv',['pair_review','--root',str(root),'--models',str(models)]), \
                 patch.object(pair_review,'configurations',return_value=([],{})), \
                 patch.object(pair_review,'build_payload',return_value={'transcripts':{'rows':[]}}), \
                 patch.object(pair_review,'candidate_pairs',side_effect=change_manifest):
                with self.assertRaisesRegex(ValueError,'changed while preparing'):
                    pair_review.main()
            self.assertEqual(result.read_bytes(),before)


if __name__ == '__main__':
    unittest.main()
