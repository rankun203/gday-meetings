"""Synthetic checks for private artifacts, native results and HTML data isolation."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from compare import page, safe_id, validate_result, run, digest
from aggregate import covered_seconds, summarize


class ComparisonTests(unittest.TestCase):
    def test_coverage_merges_overlaps_and_clips_to_audio(self):
        self.assertEqual(covered_seconds([dict(start=0,end=2),dict(start=1,end=3),dict(start=4,end=5)],4.5),3.5)

    def test_primary_matrix_stays_separate_from_latest_diagnostic(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            (root/'manifest.json').write_text(json.dumps(dict(tracks=[dict(fixture='short',track='system',durationSeconds=3)])))
            folder=root/'results/short/system'
            folder.mkdir(parents=True)
            for provider in ['apple','nemotron','whisper']:
                for iteration in ([1,3] if provider=='nemotron' else [1]):
                    path=folder/f'{provider}-{iteration}.json'
                    path.write_text(json.dumps(dict(provider=provider,status='completed',segments=[dict(start=0,end=2,text='Same text.')],model=dict(id='synthetic'),timing={},resources={},timestampGranularity='segment')))
                    path.with_suffix('.receipt.json').write_text(json.dumps(dict(elapsedSeconds=1,executableSHA256='synthetic')))
            report=summarize(root,{'short/system':1})
            self.assertTrue(all(row['selectedIteration']==1 for row in report['primaryMatrix']))
            latest=next(row for row in report['reviewSelected'] if row['provider']=='nemotron')
            self.assertEqual(latest['selectedIteration'],3)
            self.assertTrue(latest['textUnchangedFromPrimary'])

    def test_generic_identifiers_reject_path_traversal(self):
        self.assertEqual(safe_id('short-clip'), 'short-clip')
        for value in ('../meeting', '/absolute', 'name with spaces', 'a/b'):
            with self.assertRaises(ValueError):
                safe_id(value)

    def test_results_preserve_time_order_and_provider_identity(self):
        value = dict(schemaVersion=1, provider='apple', status='completed', segments=[dict(start=0, end=2, text='Hello.')])
        validate_result(value, 'apple', 3)
        with self.assertRaises(ValueError):
            validate_result(value, 'whisper', 3)
        value['segments'].append(dict(start=-1, end=1, text='Invalid.'))
        with self.assertRaises(ValueError):
            validate_result(value, 'apple', 3)

    def test_invalid_native_result_preserves_raw_data_and_continues(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            audio = root/'audio.wav'
            audio.write_bytes(b'synthetic pcm')
            (root/'manifest.json').write_text(json.dumps(dict(tracks=[dict(fixture='short',track='system',
                language='en-US',audio='audio.wav',pcmSHA256=digest(audio),durationSeconds=3)])))
            config = dict(providers={key:dict(executable='/usr/bin/true',modelRoot=temp) for key in ['apple','whisper']})
            def native(command, log, timeout):
                provider = command[command.index('--provider')+1]
                output = Path(command[command.index('--output')+1])
                output.write_text('invalid json' if provider == 'apple' else json.dumps(dict(schemaVersion=1,
                    provider=provider,status='completed',segments=[dict(start=0,end=2,text='Hello.')])))
                return 0
            with patch('compare.run_process', side_effect=native):
                run(config,root,['apple','whisper'],1)
            folder=root/'results/short/system'
            self.assertEqual(json.loads((folder/'apple-0.json').read_text())['status'],'failed')
            self.assertTrue((folder/'apple-0.raw.json').is_file())
            self.assertEqual(json.loads((folder/'whisper-0.json').read_text())['status'],'completed')

    def test_page_embeds_escaped_text_and_marks_missing_provider(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            track = dict(fixture='short', track='system', label='Short Recording', audio='audio/short/system.wav',
                         durationSeconds=3, language='en-US', pcmSHA256='synthetic')
            (root/'manifest.json').write_text(json.dumps(dict(tracks=[track])))
            folder = root/'results/short/system'
            folder.mkdir(parents=True)
            (folder/'apple-0.json').write_text(json.dumps(dict(provider='apple',status='completed',segments=[dict(start=0,end=2,text='</script><script>bad()</script>')])))
            rendered = page(root, 1).read_text()
            self.assertIn('\\u003c/script>', rendered)
            self.assertNotIn('</script><script>bad()', rendered)
            self.assertIn('"status": "pending"', rendered)
            self.assertNotIn('fetch(', rendered)
            self.assertIn('resultSHA256', rendered)
            self.assertIn("result.provider+':'+result.resultSHA256", rendered)
            original = rendered
            (folder/'apple-0.json').write_text(json.dumps(dict(provider='apple',status='completed',segments=[dict(start=0,end=2,text='Changed result.')])))
            self.assertNotEqual(original, page(root, 1).read_text())
            (folder/'apple-1.json').write_text(json.dumps(dict(provider='apple',status='completed',segments=[dict(start=0,end=2,text='Successful retry.')])))
            retried=page(root,1).read_text()
            self.assertIn('Successful retry.',retried)
            self.assertIn('\"selectedIteration\": 1',retried)
            (folder/'apple-2.json').write_text(json.dumps(dict(provider='apple',status='failed',segments=[])))
            self.assertIn('Successful retry.',page(root,1).read_text())


if __name__ == '__main__':
    unittest.main()
