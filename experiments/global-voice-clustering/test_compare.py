"""Synthetic regression checks for clustering and reversible identity decisions."""
import copy
import math
import unittest

import compare


def sample(sid, angle=0., person=None, **extra):
    return {'id': sid, 'model': 'model-a', 'embedding': [math.cos(angle), math.sin(angle)],
            'meeting_id': sid, 'meeting_order': 0, 'local_speaker': sid, 'eligible': True,
            'confirmed': person is not None, 'person_id': person, 'density_key': sid,
            'duration': 3., **extra}


class CompareTests(unittest.TestCase):
    def derive(self, rows, **options):
        groups, core = compare.dbscan(rows, compare.matrix(rows), **options)
        return compare.assign_groups(rows, groups, 'test', core=core)

    def test_noise_observations_have_distinct_groups(self):
        result = self.derive([sample('a', 0), sample('b', 2.)])
        self.assertNotEqual(result['a']['group'], result['b']['group'])
        self.assertTrue(all(row['person_id'] is None for row in result.values()))
        self.assertEqual(compare.metrics(result)['noise_samples'], 2)

    def test_singleton_core_is_not_noise(self):
        result = self.derive([sample('a')], min_samples=1)
        self.assertEqual(compare.metrics(result)['noise_samples'], 0)
        self.assertEqual(compare.metrics(result)['core_samples'], 1)

    def test_model_compatibility_and_dimension_partition(self):
        rows = [sample('a'), sample('b', model='model-b'), sample('c', embedding=[1., 0., 0.])]
        result = self.derive(rows, min_samples=2, threshold=-1)
        self.assertEqual(len({row['group'] for row in result.values()}), 3)

    def test_bridge_conflict_preserves_explicit_identity(self):
        rows = [sample('a', 0., 'person-a'), sample('b', .5), sample('c', 1., 'person-b')]
        result = self.derive(rows, min_samples=2, threshold=.8)
        self.assertEqual(result['a']['group'], result['c']['group'])
        self.assertEqual(result['a']['person_id'], 'person-a')
        self.assertEqual(result['c']['person_id'], 'person-b')
        self.assertIsNone(result['b']['person_id'])
        self.assertEqual(result['b']['state'], 'conflict')

    def test_complete_link_prevents_transitive_chain(self):
        rows = [sample('a', 0.), sample('b', .5), sample('c', 1.)]
        groups = compare.complete_link(compare.matrix(rows), margin=0)
        self.assertFalse(any(len(group) == 3 for group in groups))

    def test_complete_link_margin_defers_ambiguous_member(self):
        sim = compare.np.array([[1., .9, .83], [.9, 1., .7], [.83, .7, 1.]])
        groups = compare.complete_link(sim, margin=.08)
        self.assertIn([0], groups)
        self.assertIn([1], groups)

    def test_rejection_veto_does_not_promote_runner_up(self):
        rows = [sample('a', 0., 'person-a'), sample('b', .4, 'person-b'),
                sample('c', .01, rejected_person_ids=['person-a'])]
        result, _ = compare.recognition(rows, compare.matrix(rows))
        self.assertIsNone(result['c']['person_id'])
        self.assertEqual(result['c']['state'], 'rejected')

    def test_duplicate_aliases_are_not_novel_identity_evidence(self):
        rows = [sample('a', person='person-a', density_key='same'),
                sample('b', density_key='same'), sample('c', density_key='same')]
        methods = compare.run_methods(rows)
        raw = methods['global_dbscan']['metrics']
        self.assertEqual(raw['inferred_samples'], 2)
        self.assertEqual(raw['inferred_novel_physical_samples'], 0)
        self.assertEqual(raw['inferred_duplicate_anchor_samples'], 2)
        self.assertEqual(methods['global_dbscan_unique']['metrics']['inferred_samples'], 0)

    def test_profile_cap_is_per_person_model(self):
        rows = [sample(str(i).zfill(3), i * .01, 'person-a') for i in range(20)]
        sim = compare.matrix(rows)
        self.assertEqual(len(compare.profile_indices(rows, sim)), 12)
        self.assertEqual(len(compare.profile_indices(rows, sim, 99)), 20)

    def test_conflicting_exact_evidence_excluded_from_profiles(self):
        rows = [sample('a', person='person-a', density_key='same'),
                sample('b', person='person-b', density_key='same'), sample('c')]
        result, references = compare.recognition(rows, compare.matrix(rows))
        self.assertEqual(references, 0)
        self.assertIsNone(result['c']['person_id'])

    def test_duplicate_density_sensitivity(self):
        rows = [sample(str(i), density_key='one', meeting_id='meeting', local_speaker='label') for i in range(8)]
        self.assertEqual(compare.metrics(self.derive(rows))['grouped_samples'], 8)
        for density in ['exact_support', 'meeting_label']:
            self.assertEqual(compare.metrics(self.derive(rows, density=density))['grouped_samples'], 0)

    def test_comembership_change_ignores_group_label_permutations(self):
        before = {str(i): {'group': 'a' if i < 2 else 'b', 'person_id': None} for i in range(4)}
        after = copy.deepcopy(before)
        for row in after.values():
            row['group'] += '-new'
        self.assertEqual(compare.changes(before, after)['co_membership_changed_pairs'], 0)
        after['0']['group'] = after['2']['group']
        self.assertEqual(compare.changes(before, after)['co_membership_changed_pairs'], 3)

    def test_empty_meetings_remain_in_replay_coverage(self):
        fixture = {'samples': [sample('a', meeting_id='m2', meeting_order=1)],
                   'meetings': [{'id': 'm1', 'meeting_order': 0}, {'id': 'm2', 'meeting_order': 1}]}
        result = compare.evaluate(fixture)
        self.assertEqual(result['coverage']['meetings'], 2)
        self.assertEqual(result['coverage']['vector_bearing_meetings'], 1)
        growing = result['scenarios'][0]['checkpoints']
        self.assertEqual([row['samples'] for row in growing], [0, 1])

    def test_lifecycle_checks(self):
        result = compare.synthetic_lifecycle()
        self.assertTrue(all(result['checks'].values()), result)
        self.assertGreater(result['model_replacement']['identity_changed'], 0)

    def test_exclusion_and_undo(self):
        rows = [sample('a', person='person-a'), sample('b'), sample('c')]
        before = self.derive(rows)
        excluded = copy.deepcopy(rows)
        excluded[0]['eligible'] = False
        result = self.derive(excluded)
        self.assertEqual(result['a']['person_id'], 'person-a')
        self.assertIsNone(result['b']['person_id'])
        self.assertEqual(self.derive(rows), before)

    def test_relative_suggestion_requires_competing_person(self):
        rows = [sample('a', person='person-a'), sample('b', .8)]
        result, _ = compare.recognition(rows, compare.matrix(rows))
        self.assertEqual(result['b']['state'], 'unknown')
        rows.append(sample('c', 2., 'person-b'))
        result, _ = compare.recognition(rows, compare.matrix(rows))
        self.assertEqual(result['b']['state'], 'tentative')


if __name__ == '__main__':
    unittest.main()
