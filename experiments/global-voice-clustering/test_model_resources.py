"""Synthetic checks for resource projection and export-validation boundaries."""
import copy
import json
from pathlib import Path
import tempfile
import unittest

from model_resources import assemble, digest, interpolate, project


class ResourceTests(unittest.TestCase):
    def test_interpolation_and_duration_weighting(self):
        self.assertAlmostEqual(interpolate({2.: .02, 3.: .04, 5.: .08}, 4), .06)
        result = project({2.: 2, 4.: 1}, {2.: .1, 3.: .2, 5.: .4},
                         {2.: .02, 3.: .04, 5.: .08}, .001)
        self.assertAlmostEqual(result['serial_seconds'], .603)
        self.assertEqual(result['projected_jobs'], 3)

    def test_outside_measured_range_withholds_partial_total(self):
        result = project({2.: 2, 6.: 1}, {2.: .1, 5.: .3}, {2.: .02, 5.: .04}, .001)
        self.assertIsNone(result['serial_seconds'])
        self.assertIsNone(result['frontend_seconds'])
        self.assertEqual(result['unprojected_jobs'], 1)

    def fixture(self, root):
        def save(name, value):
            path = root / (name + '.json')
            path.write_text(json.dumps(value))
            return str(path)
        prepared = dict(provenance={'input_sha256': 'source'},
                        jobs=[{'sample_count': duration*16000} for duration in (2, 3, 5)], aliases=[{}, {}, {}])
        prepared_path = save('prepared', prepared)
        metadata = dict(model_id='synthetic', checkpoint_sha256='synthetic-hash', checkpoint_bytes=100,
                        device='mps')
        summary = dict(complete=True, unique_jobs=3, expected_rows=3, model_metadata=metadata,
                       load_seconds=.5, new_inference_seconds=1.)
        stage = dict(stage='synthetic-extraction', status='completed', exit_status=0, wall_seconds=2.,
                     cpu_and_process_peak={'peak_rss_bytes': 1000000}, cwd=str(root),
                     command=['python', 'model_extract.py', 'extract', '--output', str(root), '--prepared', prepared_path])
        cases = [dict(label=f'case-{duration}', sample_count=16000*duration, package_bytes=100, package=f'model-{duration}.mlpackage') for duration in (2, 3, 5)]
        conversion = dict(status='complete', adapter_metadata=metadata, cases=cases)
        conversion_path = save('conversion', conversion)
        fixtures = dict(status='complete', source_conversion_sha256=digest(conversion_path),
                        audio_sha256='audio', cases=[{'label': f'private-{duration}', 'sample_count': duration*16000} for duration in (2,3,5)])
        fixtures_path = save('fixtures', fixtures)
        prediction = dict(status='complete', run_label='native', compute_units='ALL',
                          fixture_manifest_sha256=digest(conversion_path), cases=[dict(label=case['label'],
                          parity_pass=True, warm_median_seconds=case['sample_count']/1600000) for case in cases])
        private = dict(status='complete', run_label='native-private', compute_units='ALL', fixture_manifest_sha256=digest(fixtures_path),
                       cases=[dict(label=f'private-{duration}', parity_pass=True, warm_median_seconds=duration*.01, parity={'cosine': .99999}) for duration in (2,3,5)])
        entry = dict(model_id='synthetic', prepared_path=prepared_path,
                     extraction_provenance=save('provenance', dict(prepared_sha256=digest(prepared_path), model_metadata=metadata)), summary=save('summary', summary),
                     extraction_receipt=save('extract-stage', stage), conversion=conversion_path,
                     conversion_receipt=save('convert-stage', dict(stage, stage='synthetic-conversion', command=['python', 'coreml_benchmark.py', 'convert', '--output', str(root), '--model-id', 'synthetic'])),
                     predictions=[save('prediction-ALL-native', prediction)], prediction_receipts=[],
                     private_prediction=save('prediction-ALL-native-private', private), private_fixtures=fixtures_path)
        results = dict(metadata={'full_speech_input_sha256': 'source'}, methods={'preserved': {}})
        frontend = dict(status='complete', threads=4, audio_sha256='audio', models=[dict(model_id='synthetic', status='complete',
                        cpu_metadata=metadata, normalization_median_seconds=.001,
                        cases=[dict(seconds=duration, frontend_median_seconds=.1) for duration in (2, 3, 5)])])
        return results, prepared, entry, frontend

    def test_only_verified_export_gets_projection_and_preserves_results(self):
        with tempfile.TemporaryDirectory() as directory:
            results, prepared, entry, frontend = self.fixture(Path(directory))
            value = assemble(copy.deepcopy(results), prepared, [entry], frontend, {}, prepared_sha256=digest(entry['prepared_path']))
            self.assertIn('preserved', value['methods'])
            row = value['coreml_resources'][0]
            self.assertAlmostEqual(row['projection_serial_seconds'], .403)
            self.assertEqual(row['warm_3s_ms'], 30)
            self.assertEqual(row['conversion_peak_process_mb'], 1)
            self.assertEqual(row['all_fixed_shape_packages_mb'], .0003)
            entry['predictions'] = []
            private_only = assemble(copy.deepcopy(results), prepared, [entry], frontend, {}, prepared_sha256=digest(entry['prepared_path']))
            self.assertAlmostEqual(private_only['coreml_resources'][0]['projection_serial_seconds'], .403)
            self.assertIsNone(row['runtime_peak_process_mb'])

    def test_failed_private_parity_cannot_publish_fast_timing(self):
        with tempfile.TemporaryDirectory() as directory:
            results, prepared, entry, frontend = self.fixture(Path(directory))
            path = Path(entry['private_prediction'])
            failed = json.loads(path.read_text())
            failed['status'] = 'failed'
            failed['cases'][0]['parity_pass'] = False
            path.write_text(json.dumps(failed))
            value = assemble(results, prepared, [entry], frontend, {}, prepared_sha256=digest(entry['prepared_path']))
            row = value['coreml_resources'][0]
            self.assertIsNone(row['projection_serial_seconds'])
            self.assertIsNone(row['warm_3s_ms'])
            self.assertIn('failed', row['status'])

    def test_source_and_frontend_configuration_must_match(self):
        with tempfile.TemporaryDirectory() as directory:
            results, prepared, entry, frontend = self.fixture(Path(directory))
            frontend['threads'] = 2
            with self.assertRaisesRegex(ValueError, 'four'):
                assemble(results, prepared, [entry], frontend, {}, prepared_sha256=digest(entry['prepared_path']))
            frontend['threads'] = 4
            results['metadata']['full_speech_input_sha256'] = 'changed'
            with self.assertRaisesRegex(ValueError, 'different'):
                assemble(results, prepared, [entry], frontend, {}, prepared_sha256=digest(entry['prepared_path']))

    def test_private_grid_cannot_borrow_a_synthetic_duration(self):
        with tempfile.TemporaryDirectory() as directory:
            results, prepared, entry, frontend = self.fixture(Path(directory))
            fixtures_path, private_path = Path(entry['private_fixtures']), Path(entry['private_prediction'])
            fixtures, private = json.loads(fixtures_path.read_text()), json.loads(private_path.read_text())
            fixtures['cases'] = fixtures['cases'][:2]
            private['cases'] = private['cases'][:2]
            fixtures_path.write_text(json.dumps(fixtures))
            private['fixture_manifest_sha256'] = digest(fixtures_path)
            private_path.write_text(json.dumps(private))
            value = assemble(results, prepared, [entry], frontend, {}, prepared_sha256=digest(entry['prepared_path']))
            self.assertIsNone(value['coreml_resources'][0]['projection_serial_seconds'])
            self.assertIsNone(value['coreml_resources'][0]['warm_5s_ms'])

    def test_conversion_memory_cannot_use_an_extraction_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            results, prepared, entry, frontend = self.fixture(Path(directory))
            entry['conversion_receipt'] = entry['extraction_receipt']
            with self.assertRaisesRegex(ValueError, 'coreml_benchmark'):
                assemble(results, prepared, [entry], frontend, {}, prepared_sha256=digest(entry['prepared_path']))

    def test_runtime_rss_rejects_an_extraction_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            results, prepared, entry, frontend = self.fixture(Path(directory))
            entry['prediction_receipts'] = [entry['extraction_receipt']]
            with self.assertRaisesRegex(ValueError, 'coreml_benchmark'):
                assemble(results, prepared, [entry], frontend, {}, prepared_sha256=digest(entry['prepared_path']))

    def test_runtime_rss_requires_exact_native_prediction_binding(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            results, prepared, entry, frontend = self.fixture(root)
            receipt = dict(stage='native-private', cwd=str(root), status='completed', exit_status=0,
                           command=['python', 'coreml_benchmark.py', 'predict', '--output', str(root),
                                    '--compute-units', 'ALL', '--run-label', 'native-private',
                                    '--fixtures-manifest', entry['private_fixtures']],
                           cpu_and_process_peak={'peak_rss_bytes': 2000000})
            path = root / 'runtime.json'
            path.write_text(json.dumps(receipt))
            entry['prediction_receipts'] = [str(path)]
            value = assemble(copy.deepcopy(results), prepared, [entry], frontend, {}, prepared_sha256=digest(entry['prepared_path']))
            self.assertEqual(value['coreml_resources'][0]['runtime_peak_process_mb'], 2)
            receipt['command'][receipt['command'].index('--run-label') + 1] = 'native-other'
            path.write_text(json.dumps(receipt))
            with self.assertRaisesRegex(ValueError, 'bound'):
                assemble(results, prepared, [entry], frontend, {}, prepared_sha256=digest(entry['prepared_path']))

    def test_failed_frontend_receipt_cannot_publish_leaf_success(self):
        with tempfile.TemporaryDirectory() as directory:
            results, prepared, entry, frontend = self.fixture(Path(directory))
            frontend.update(status='failed', error='Input windows changed during measurement.')
            with self.assertRaisesRegex(ValueError, 'Frontend'):
                assemble(results, prepared, [entry], frontend, {}, prepared_sha256=digest(entry['prepared_path']))

    def test_extraction_provenance_must_match_prepared_file(self):
        with tempfile.TemporaryDirectory() as directory:
            results, prepared, entry, frontend = self.fixture(Path(directory))
            path = Path(entry['extraction_provenance'])
            provenance = json.loads(path.read_text())
            provenance['prepared_sha256'] = 'other-prepared-plan'
            path.write_text(json.dumps(provenance))
            with self.assertRaisesRegex(ValueError, 'provenance'):
                assemble(results, prepared, [entry], frontend, {}, prepared_sha256=digest(entry['prepared_path']))

    def test_failed_attempts_with_same_stage_are_retained(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            results, prepared, entry, frontend = self.fixture(root)
            attempts = []
            for index in (1, 2):
                path = root / f'failed-{index}.json'
                path.write_text(json.dumps(dict(stage='same-stage', started_at=f'attempt-{index}', status='failed')))
                attempts.append(path)
            value = assemble(results, prepared, [entry], frontend, {}, attempts, prepared_sha256=digest(entry['prepared_path']))
            self.assertEqual(len([stage for stage in value['resources']['stages'] if stage['stage'] == 'same-stage']), 2)
            self.assertEqual(value['model_resources'][0]['extraction_attempt_wall_seconds'], 2)
            self.assertNotIn('full_extraction_wall_seconds', value['model_resources'][0])


if __name__ == '__main__':
    unittest.main()
