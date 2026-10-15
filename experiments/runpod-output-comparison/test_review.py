import json
from pathlib import Path
import sys
import unittest
import subprocess

sys.path.insert(0, str(Path(__file__).parent))
import review


class ReviewTests(unittest.TestCase):
    def fixture(self):
        state = {'tracks': [{'track': 'b', 'source': 'system', 'sha256': 'hash'}]}
        metrics = {'tracks': {'b': {'source': 'system', 'audio_sha256': 'hash',
                                   'local_to_remote_speaker_mapping': {'local': 'remote'}, 'difference_windows': []}}}
        remote = {'status': 'COMPLETED', 'output': {'tracks': {'b': {'segments': [{'speaker': 'remote', 'words': [
            {'word': 'First', 'start': 0, 'end': 1, 'speaker': 'remote'},
            {'word': 'next', 'start': 1, 'end': 2, 'speaker': 'remote'},
            {'word': 'unknown', 'start': 2, 'end': 3},
            {'word': 'untimed', 'speaker': 'remote'}]}]}}}}
        local = [{'source': 'system', 'start': 0, 'end': 2, 'text': 'First next', 'speakerID': 'local',
                  'speaker': 'Local', 'associationUncertain': True,
                  'timing': {'text': 'First next', 'spans': [{'start': 0, 'end': 1}]}}]
        return local, remote, state, metrics

    def test_safe_embedded_json_and_dom_text(self):
        dangerous = '</script><script>alert(1)</script><img src=x onerror=alert(2)>&\u2028'
        html = review.render({'text': dangerous})
        self.assertNotIn(dangerous, html)
        encoded = html.split('<script id="data" type="application/json">')[1].split('</script>')[0]
        self.assertEqual(json.loads(encoded)['text'], dangerous)
        self.assertNotIn('innerHTML', html)
        self.assertIn("connect-src 'none'", html)

    def test_track_mapping_labels_and_untimed_words(self):
        local, remote, state, metrics = self.fixture()
        result = review.model(local, remote, state, metrics)['tracks']['b']
        self.assertEqual(result['source'], 'system')
        self.assertTrue(result['local'][0]['uncertain'])
        self.assertEqual(result['local'][0]['mapped'], 'remote')
        self.assertEqual(result['remote'][0]['words'], ['First', 'next'])
        self.assertIsNone(result['remote'][1]['label'])
        self.assertEqual(result['untimedRemoteText'], ['untimed'])
        self.assertEqual([w['start'] for w in result['windows'][:4]], [0, 30, 60, 90])
        self.assertTrue(any(w['sampling'] == 'uniform' for w in result['windows']))
        metrics['tracks']['b']['audio_sha256'] = 'other'
        with self.assertRaises(ValueError):
            review.model(local, remote, state, metrics)

    def test_source_only_local_and_no_word_segments_remain_explicit(self):
        local, remote, state, metrics = self.fixture()
        local[0]['sourcePlaceholder'] = True
        local[0].pop('timing')
        remote['output']['tracks']['b']['segments'].append({'text': 'Unaligned segment'})
        result = review.model(local, remote, state, metrics)['tracks']['b']
        self.assertIsNone(result['local'][0]['label'])
        self.assertFalse(result['local'][0]['timed'])
        self.assertIn('Unaligned segment', result['untimedRemoteText'])

    def test_exact_character_tokens_preserve_chinese_and_english_spacing(self):
        text = '你好 stage API。'
        tokens = list('你好stageAPI')
        segment = {'text': text, 'words': [{'word': token, 'start': i, 'end': i + .5, 'speaker': 'x'}
                                           for i, token in enumerate(tokens)]}
        slices = review.exact_word_slices(segment)
        self.assertTrue(all(exact for _, _, exact in slices))
        self.assertEqual(''.join(piece for _, piece, _ in slices), text)
        local, remote, state, metrics = self.fixture()
        remote['output']['tracks']['b']['segments'] = [segment]
        output = review.model(local, remote, state, metrics)['tracks']['b']['remote']
        self.assertEqual(len(output), 1)
        self.assertEqual(output[0]['text'], text)
        self.assertTrue(output[0]['exactText'])
        segment['text'] = 'Missing ' + text
        self.assertTrue(all(not exact for _, _, exact in review.exact_word_slices(segment)))

    def test_unmatched_tokens_remain_readable_without_invented_source_matching(self):
        tokens = ['你好', '，', 's', 't', 'a', 'g', 'e', ' ', 'A', 'P', 'I', '。']
        self.assertEqual(review.readable_tokens(tokens), '你好，stage API。')
        self.assertEqual(review.readable_tokens(['First', 'next', '.']), 'First next.')
        self.assertEqual(review.readable_tokens(['one ', '  two']), 'one   two')
        local, remote, state, metrics = self.fixture()
        segment = {'text': 'Different source text', 'words': [
            {'word': token, 'start': i, 'end': i + .5, 'speaker': 'x'}
            for i, token in enumerate(tokens)]}
        remote['output']['tracks']['b']['segments'] = [segment]
        rows = review.model(local, remote, state, metrics)['tracks']['b']['remote']
        self.assertEqual(rows[0]['text'], '你好，stage API。')
        self.assertFalse(rows[0]['exactText'])
        self.assertEqual(rows[0]['words'], tokens)

    def test_feedback_contract_retains_blinding_mapping_sampling_and_preference(self):
        script = r"""
const assert = require('node:assert/strict');
const c = require(process.argv[1]);
const methods = [{id:'baseline',name:'Baseline'}, {id:'candidate',name:'Candidate'}];
const key = c.key('track0', 10, 40), mapping = c.sides('synthetic', key, methods);
assert.deepEqual(Object.values(mapping).sort(), ['baseline','candidate']);
assert.deepEqual(c.sides('synthetic', key, methods), mapping);
const entry = c.entry({reviewId:'synthetic',track:'track0',source:'system',audioHash:'hash',
 start:10,end:40,mapping,choice:'B',issues:['wrong_speaker'],notes:'Review this change.',revealed:true,sampling:'uniform'});
assert.equal(entry.preferredMethod,mapping.B);
assert.equal(entry.methodNamesRevealed,true);
assert.equal(entry.sampling,'uniform');
const output = c.feedback('synthetic',methods,{[key]:entry});
assert.equal(output.kind,'listening_preference_not_ground_truth');
assert.equal(output.reviews.length,1);
assert.equal(output.version,2);
assert.deepEqual(output.reviews[0].mapping,mapping);
assert.equal(c.entry({...entry,choice:'same'}).preferredMethod,null);
assert.equal(c.entry({...entry,choice:'unsure'}).preferredMethod,null);
assert.throws(()=>c.entry({...entry,choice:'invented'}));
assert.equal(c.feedback('different',methods,{[key]:entry}).reviews.length,0);
"""
        subprocess.run(['node', '-e', script, str(Path(__file__).with_name('review_contract.js').resolve())], check=True)


if __name__ == '__main__':
    unittest.main()
