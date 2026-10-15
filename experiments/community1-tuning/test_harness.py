"""Synthetic configuration and normalized-result checks; no model loading."""
import json
import subprocess
import unittest
from pathlib import Path
from run import normalize
from summarize import fixed_support, conservation

BINARY = Path(__file__).resolve().parent/'.local/package/.build/release/Community1Benchmark'


class HarnessTests(unittest.TestCase):
    def test_profile_changes_only_intended_setting(self):
        configs = {}
        for name in ['baseline', 'dense', 'overlap']:
            output = subprocess.check_output([str(BINARY), 'unused', '--configuration', name, '--describe-configuration'], text=True)
            configs[name] = json.loads(output)
        baseline = configs['baseline']['complete_configuration']
        self.assertEqual(configs['baseline']['segmentation_step_ratio'], .2)
        self.assertEqual(configs['dense']['complete_configuration'], baseline.replace('stepRatio: 0.2', 'stepRatio: 0.1'))
        self.assertEqual(configs['overlap']['complete_configuration'], baseline.replace('exclusiveSegments: true', 'exclusiveSegments: false'))
        result = subprocess.run([str(BINARY), 'unused', '--configuration', 'unknown', '--describe-configuration'], capture_output=True)
        self.assertNotEqual(result.returncode, 0)

    def test_fixed_support_uses_identical_labeled_population(self):
        result = fixed_support([[(0,4,'A')], [(0,1,'B'),(1,2,'C'),(2,4,None)]],
                               [(0,4,'X')], [{'A':'X'},{'B':'X','C':'Y'}])
        self.assertEqual(result['commonSeconds'], 2)
        self.assertEqual(result['baselineDisagreementSeconds'], 0)
        self.assertEqual(result['denseDisagreementSeconds'], 1)
        source = [{'id':'source', 'text':'Ab'}]
        row = {'text':'Ab', 'sourceSpans':[{'rowID':'source', 'range':{'location':0,'length':2}, 'text':'Ab'}]}
        self.assertTrue(conservation(source,[row])['preservedExactlyOnce'])
        with self.assertRaises(AssertionError): conservation(source,[row,row])
        with self.assertRaises(AssertionError): conservation(source,[])

    def test_normalization_retains_overlap_and_scopes_speakers(self):
        tracks = [{'track': f'track{i}', 'source': source, 'sha256': str(i), 'duration': 3,
                   'segments': [{'speaker': 'speaker_0', 'start_seconds': 0., 'end_seconds': 2.},
                                {'speaker': 'speaker_1', 'start_seconds': 1., 'end_seconds': 3.}]}
                  for i, source in enumerate(['microphone', 'system'])]
        first = normalize('baseline', tracks)
        second = normalize('baseline', tracks)
        self.assertEqual(first['speakers'], second['speakers'])
        self.assertEqual(len({s['id'] for s in first['speakers']}), 4)
        self.assertEqual(len(first['ranges']), 4)
        self.assertEqual(first['trackSources'], {'track0': 'microphone', 'track1': 'system'})
        tracks[0]['segments'][0]['end_seconds'] = 4
        with self.assertRaises(ValueError): normalize('baseline', tracks)


if __name__ == '__main__': unittest.main()
