import importlib.util
from pathlib import Path
import unittest
import tempfile
import stat

spec = importlib.util.spec_from_file_location('comparison', Path(__file__).with_name('compare.py'))
comparison = importlib.util.module_from_spec(spec)
spec.loader.exec_module(comparison)


class ComparisonTests(unittest.TestCase):
    def test_global_mapping_beats_greedy_and_handles_extra_speaker(self):
        weights = {('a', 'x'): 8, ('a', 'y'): 7, ('b', 'x'): 7, ('b', 'y'): 0,
                   ('c', 'x'): 1, ('c', 'y'): 1}
        self.assertEqual(comparison.maximum_mapping(weights), {'a': 'y', 'b': 'x'})

    def test_permuted_labels_agree_without_comparing_label_strings(self):
        result = comparison.compare_track([(0, 2, 'one'), (2, 4, 'two')],
                                          [(0, 2, 'z'), (2, 4, 'a')])
        self.assertEqual(result['mapped_agreement_fraction'], 1)
        self.assertEqual(result['mutually_single_speaker_seconds'], 4)
        self.assertEqual(result['local_to_remote_speaker_mapping'], {'one': 'z', 'two': 'a'})
        self.assertEqual(result['difference_windows'], [])

    def test_coverage_ambiguity_and_duplicate_intervals_are_separate(self):
        left = [(0, 4, 'a'), (0, 2, 'a'), (1, 2, 'b'), (2, 3, None), (4, 5, None)]
        right = [(0, 5, 'x')]
        result = comparison.compare_track(left, right)
        self.assertEqual(result['local']['timed_seconds'], 5)
        self.assertEqual(result['local']['speaker_covered_seconds'], 4)
        self.assertEqual(result['local']['unresolved_only_seconds'], 1)
        self.assertEqual(result['local']['multiple_speaker_seconds'], 1)
        self.assertEqual(result['local']['assigned_and_unresolved_overlap_seconds'], 1)
        self.assertEqual(result['mutually_single_speaker_seconds'], 2)
        self.assertEqual(result['mapped_agreement_fraction'], 1)
        self.assertTrue(any(x['reason'] == 'different_attribution_coverage' for x in result['difference_windows']))

    def test_disjoint_time_has_no_agreement_denominator(self):
        result = comparison.compare_track([(0, 1, 'a')], [(1, 2, 'x')])
        self.assertIsNone(result['mapped_agreement_fraction'])
        self.assertEqual(result['mutually_single_speaker_seconds'], 0)

    def test_remote_does_not_impute_segment_label_or_untimed_words(self):
        response = {'status': 'COMPLETED', 'output': {'tracks': {'t': {'segments': [
            {'speaker': 'x', 'words': [{'word': 'One', 'start': 0, 'end': 1},
                                     {'word': 'two', 'start': 1, 'end': 2, 'speaker': 'x'},
                                     {'word': 'three', 'speaker': 'x'}]}]}}}}
        values, excluded = comparison.normalize_remote(response, [{'track': 't'}])
        self.assertEqual(values['t'], [(0, 1, None), (1, 2, 'x')])
        self.assertEqual(excluded['words_without_valid_timing'], 1)
        with self.assertRaises(ValueError):
            comparison.normalize_remote(response, [{'track': 'different'}])

    def test_local_source_only_stays_unresolved_and_stale_text_is_excluded(self):
        tracks = [{'track': 't', 'source': 'system'}]
        rows = [{'source': 'system', 'speakerID': 'placeholder', 'sourcePlaceholder': True,
                 'text': 'One', 'timing': {'text': 'One', 'spans': [{'start': 0, 'end': 1}]}},
                {'analysisTrackID': 't', 'text': 'Edited', 'timing': {'text': 'Old', 'spans': []}}]
        values, excluded = comparison.normalize_local(rows, tracks)
        self.assertEqual(values['t'], [(0, 1, None)])
        self.assertEqual(excluded['rows_without_current_timing'], 1)
        with self.assertRaises(ValueError):
            comparison.normalize_local([{'source': 'unknown'}], tracks)

    def test_blank_labels_are_unresolved(self):
        for label in ['', '  ', '\t\n', None]:
            self.assertEqual(comparison.interval(0, 1, label), (0, 1, None))

    def test_private_result_permissions_and_input_protection(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'source.json'
            source.write_text('keep')
            with self.assertRaises(ValueError):
                comparison.write_private_result(source, {}, [source])
            destination = Path(folder) / 'private' / 'result.json'
            comparison.write_private_result(destination, {'value': 1}, [source])
            self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(destination.parent.stat().st_mode), 0o700)
            self.assertEqual(source.read_text(), 'keep')
        with self.assertRaises(ValueError):
            comparison.write_private_result(Path(__file__).with_name('public-result.json'), {}, [])

    def test_invalid_intervals_are_rejected(self):
        for start, end in [(float('nan'), 2), (0, float('inf')), (-1, 2), (2, 1), (1, 1), (None, 1)]:
            self.assertIsNone(comparison.interval(start, end, 'a'))


if __name__ == '__main__':
    unittest.main()
