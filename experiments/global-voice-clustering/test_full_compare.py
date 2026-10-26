"""Synthetic full-speech comparison and density regression checks."""
import copy
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import numpy as np

import compare
import full_compare as full


def sample(identifier, angle, meeting='m1', **extra):
    return {'id': identifier, 'example_id': identifier, 'meeting_id': meeting,
            'meeting_order': int(meeting[1:]), 'model': 'synthetic', 'eligible': True,
            'embedding': [math.cos(angle), math.sin(angle)], 'density_key': identifier,
            'support_spans': [{'start': 0, 'end': 2}], 'embedding_spans': [{'start': 0, 'end': 2}], **extra}


def fixture(samples):
    return {'schema_version': 1, 'samples': samples, 'examples': [{'id': s['id']} for s in samples],
            'meetings': [{'id': f'm{i}', 'meeting_order': i} for i in range(1, 3)],
            'people': [], 'decisions': [], 'metadata': {'full_speech': {'synthetic': True}}}


def baseline_fixture():
    baseline = fixture([sample('old1', .1), sample('old2', 2., meeting='m2')])
    assignments = compare.assign_groups(baseline['samples'], [[0], [1]], 'local', cold=True)
    result = {'methods': {full.BASELINE: {'assignments': assignments, 'metrics': compare.metrics(assignments)}}, 'metadata': {}}
    return baseline, result


class FullComparisonTests(unittest.TestCase):
    def test_coverage_counts_windows_when_contexts_have_aliases(self):
        source = fixture([sample('a', 0, density_key='same'), sample('b', 0, density_key='same')])
        source['metadata']['full_speech'].update(windows=2, excluded_windows=0, failed_embedding_windows=-1)
        metadata = full.full_metadata(source)
        self.assertEqual(metadata['full_speech']['embedded_windows'], 2)
        self.assertEqual(metadata['full_speech']['failed_embedding_windows'], 0)
        self.assertEqual(source['metadata']['full_speech']['failed_embedding_windows'], -1)

    def test_sparse_algorithm_matches_reference_dbscan(self):
        samples = [sample(f'fs_{i}', angle) for i, angle in enumerate([0, .1, .2, .9, 1.5, 1.6, 1.7, 3.])]
        indices, members = full.representatives(samples)
        graph = full.neighborhood_graph(samples, block_size=2)
        for threshold in full.THRESHOLDS:
            for minimum in [3, 5]:
                groups, core = compare.dbscan(samples, compare.matrix(samples), threshold, minimum, density='exact_support')
                reference = compare.assign_groups(samples, groups, 'reference', cold=True, core=core)
                actual = full.cluster(samples, indices, members, graph, threshold, minimum, independent=False)
                self.assertEqual(compare.changes(reference, actual)['co_membership_changed_pairs'], 0)
                self.assertEqual({sid: row['core'] for sid, row in reference.items()},
                                 {sid: row['core'] for sid, row in actual.items()})
                self.assertEqual({sid: row['noise'] for sid, row in reference.items()},
                                 {sid: row['noise'] for sid, row in actual.items()})

    def test_duplicate_physical_support_does_not_make_core(self):
        samples = [sample(f'fs_{i}', 0, density_key='same') for i in range(5)]
        indices, members = full.representatives(samples)
        self.assertEqual(len(indices), 1)
        assignments = full.cluster(samples, indices, members, full.neighborhood_graph([samples[i] for i in indices]))
        self.assertEqual(len(assignments), 5)
        self.assertTrue(all(row['noise'] for row in assignments.values()))
        self.assertTrue(all(not row['core'] for row in assignments.values()))
        counts = full.full_metrics(assignments)
        self.assertEqual(counts['grouped_samples'], 0)
        self.assertEqual(counts['non_singleton_groups'], 0)
        self.assertEqual(counts['largest_group'], 0)
        self.assertEqual(counts['noise_samples'], 5)
        samples[1]['embedding'] = [0, 1]
        with self.assertRaisesRegex(ValueError, 'conflicting embeddings'):
            full.representatives(samples)

    def test_cold_domain_exclusion_baseline_and_arrival(self):
        samples = [sample(f'fs_{i}', .01 * i, meeting='m1' if i < 2 else 'm2',
                          confirmed=True, person_id='synthetic-person') for i in range(4)]
        samples.append(sample('fs_invalid', 0, eligible=False))
        samples.append(sample('fs_model', 0, model='different-model'))
        baseline, baseline_result = baseline_fixture()
        original = copy.deepcopy(baseline_result)
        result = full.evaluate(fixture(samples), baseline, baseline_result, block_size=2)
        self.assertEqual(set(result['methods']), {full.PRIMARY, full.BASELINE})
        self.assertEqual(result['methods'][full.BASELINE], original['methods'][full.BASELINE])
        actual = result['methods'][full.PRIMARY]['assignments']
        self.assertEqual(set(actual), {s['id'] for s in samples})
        self.assertTrue(all(row['person_id'] is None for row in actual.values()))
        self.assertEqual(actual['fs_invalid']['state'], 'excluded')
        self.assertTrue(actual['fs_model']['noise'])
        self.assertEqual(len(result['sensitivity']), 8)
        self.assertEqual(result['scenarios'][0]['final_vs_full'][full.PRIMARY]['co_membership_changed_pairs'], 0)
        for sensitivity in result['sensitivity']:
            self.assertEqual(sensitivity['metrics']['samples'], len(samples))
        indices, members = full.representatives(samples)
        graph = full.neighborhood_graph([samples[i] for i in indices], block_size=2)
        first = full.cluster(samples, indices, members, graph, active=[i for i, original in enumerate(indices) if samples[original]['meeting_id'] == 'm1'])
        self.assertFalse(any(row['core'] for row in first.values()))
        self.assertTrue(all(samples[indices[i]]['meeting_id'] == 'm1' for i in [0, 1]))

    def test_context_overlap_guard_retains_all_windows(self):
        overlapping = [sample(f'fs_{i}', 0, embedding_spans=[{'start': .1 * i, 'end': 2 + .1 * i}],
                              support_spans=[{'start': .5 + .1 * i, 'end': .55 + .1 * i}], audio_path='same.wav')
                       for i in range(3)]
        indices, members = full.representatives(overlapping)
        graph = full.neighborhood_graph(overlapping)
        guarded = full.cluster(overlapping, indices, members, graph)
        self.assertEqual(len(guarded), 3)
        self.assertTrue(all(row['noise'] and not row['core'] for row in guarded.values()))
        disjoint = copy.deepcopy(overlapping)
        for i, row in enumerate(disjoint):
            row['embedding_spans'] = [{'start': i * 2, 'end': i * 2 + 2}]
        guarded = full.cluster(disjoint, indices, members, graph)
        self.assertTrue(all(row['core'] for row in guarded.values()))
        different_files = copy.deepcopy(overlapping)
        for i, row in enumerate(different_files):
            row['audio_path'] = f'file{i}.wav'
        guarded = full.cluster(different_files, indices, members, graph)
        self.assertTrue(all(row['core'] for row in guarded.values()))
        for row in different_files:
            row['audio_revision'] = 'a' * 64
        guarded = full.cluster(different_files, indices, members, graph)
        self.assertTrue(all(row['noise'] for row in guarded.values()))

    def test_growing_samples_keeps_future_aliases_out(self):
        samples = [sample(f'fs_{i:02}', 0, density_key='same' if i < 3 else f'unique-{i}',
                          support_spans=[{'start': i // 3 * 3, 'end': i // 3 * 3 + 2}],
                          embedding_spans=[{'start': i // 3 * 3, 'end': i // 3 * 3 + 2}]) for i in range(12)]
        baseline, old = baseline_fixture()
        result = full.evaluate(fixture(samples), baseline, old)
        scenario = next(row for row in result['scenarios'] if row['name'] == 'growing_samples')
        self.assertEqual([row['samples'] for row in scenario['checkpoints']], [2, 4, 6, 8, 10, 12])
        for row in scenario['checkpoints']:
            self.assertEqual(row['methods'][full.PRIMARY]['metrics']['samples'], row['samples'])
            self.assertEqual(row['methods'][full.BASELINE]['metrics']['samples'], 2)
        self.assertEqual(scenario['final_vs_full'][full.PRIMARY]['co_membership_changed_pairs'], 0)

    def test_receipts_preserve_failed_interrupted_and_running_attempts(self):
        with tempfile.TemporaryDirectory() as temp:
            paths = []
            raw = []
            for i, status in enumerate(['completed', 'failed', 'interrupted', 'running']):
                path = Path(temp) / f'attempt-{i}.json'
                receipt = {'stage': 'synthetic', 'status': status, 'wall_seconds': i + 1,
                           'cpu_and_process_peak': {'peak_rss_bytes': None}, 'limitations': ['Synthetic limit.']}
                path.write_text(json.dumps(receipt))
                paths.append(path)
                raw.append(receipt)
            result = {}
            full.attach_resources(result, paths)
            self.assertEqual(result['resources']['stages'], raw)
            self.assertEqual(result['resources']['attempt_status_counts'],
                             {'completed': 1, 'failed': 1, 'interrupted': 1, 'running': 1})
            self.assertEqual(len(result['resources']['receipts']), 4)
            self.assertEqual(result['resources']['limitations'].count('Synthetic limit.'), 1)

    def test_memory_guard_and_zero_observations(self):
        with self.assertRaisesRegex(ValueError, 'edge limit'):
            full.neighborhood_graph([sample(str(i), 0) for i in range(4)], block_size=1, max_edges=3)
        self.assertEqual(full.neighborhood_graph([]).shape, (0, 0))
        self.assertEqual(full.cluster([], [], [], full.neighborhood_graph([])), {})

    def test_cli_preserves_raw_and_hashes_review_input(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fresh = fixture([sample('fs_1', 0), sample('fs_2', .1), sample('fs_3', .2)])
            baseline, old = baseline_fixture()
            fresh_path = root / 'fresh.json'
            baseline_path = root / 'baseline.json'
            old_path = root / 'old.json'
            fresh_path.write_text(json.dumps(fresh))
            baseline_path.write_text(json.dumps(baseline))
            old['metadata']['input_sha256'] = hashlib.sha256(baseline_path.read_bytes()).hexdigest()
            old_path.write_text(json.dumps(old))
            output = root / 'out'
            process = subprocess.run([sys.executable, str(Path(full.__file__)), '--full', str(fresh_path),
                '--baseline', str(baseline_path), '--baseline-results', str(old_path), '--output-root', str(output)],
                capture_output=True, text=True)
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertEqual((output / 'full-speech-enriched.json').read_bytes(), fresh_path.read_bytes())
            result = json.loads((output / 'results.json').read_text())
            combined = json.loads((output / 'review-input.json').read_text())
            self.assertEqual(len(combined['samples']), 5)
            self.assertEqual(result['metadata']['input_sha256'], hashlib.sha256((output / 'review-input.json').read_bytes()).hexdigest())
            self.assertEqual(result['methods'][full.BASELINE], old['methods'][full.BASELINE])
            self.assertTrue(result['full_speech']['synthetic'])
            self.assertEqual(result['full_speech']['embedded_windows'], 3)
            self.assertEqual(result['full_speech']['failed_embedding_windows'], 0)
            receipt_path = root / 'resources.json'
            receipt = {'stage': 'comparison', 'status': 'completed', 'wall_seconds': .2}
            receipt_path.write_text(json.dumps(receipt))
            # The original graph has nine edges. A cap of one proves this follow-up avoids graph construction.
            attach_command = [sys.executable, str(Path(full.__file__)), '--full', str(fresh_path),
                '--baseline', str(baseline_path), '--baseline-results', str(old_path), '--output-root', str(output),
                '--resources-only', '--max-neighbor-edges', '1', '--resource-receipt', str(receipt_path)]
            attached = subprocess.run(attach_command, capture_output=True, text=True)
            self.assertEqual(attached.returncode, 0, attached.stderr)
            updated = json.loads((output / 'results.json').read_text())
            self.assertEqual(updated['resources']['stages'], [receipt])
            self.assertEqual(updated['methods'], result['methods'])
            self.assertEqual(updated['metadata'], result['metadata'])
            unchanged = (output / 'results.json').read_bytes()
            baseline_path.write_text(json.dumps({**baseline, 'modified': True}))
            rejected = subprocess.run(attach_command, capture_output=True, text=True)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertEqual((output / 'results.json').read_bytes(), unchanged)



if __name__ == '__main__':
    unittest.main()
