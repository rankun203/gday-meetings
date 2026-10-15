import copy
import json
from pathlib import Path
import subprocess
import tempfile
import stat
import unittest

import render


def fixture():
    return {'version':1,'reviewId':'batch','inputHash':'hash','tracks':{'a':{
        'source':'system','audio':'audio.wav','sha256':'audiohash','duration':100}},
        'items':[{'id':'clip1','track':'a','start':1,'end':8,'partition':'hidden_holdout','category':'model_failure',
                  'contextText':'Hello 世界。','prediction':'secret',
                  'targets':[{'id':'t1','type':'timedText','text':'世界','start':3,'end':4,'contextRange':{'location':6,'length':2},'speakerID':'secret'},
                             {'id':'t2','type':'timedText','text':'Hello','start':1,'end':2,'contextRange':{'location':0,'length':5}}],
                  'references':[{'id':'r1','label':'Reference A','start':9,'end':10,'relation':'next'}]}]}


class AnnotationTests(unittest.TestCase):
    def test_public_payload_omits_predictions_and_partitions(self):
        data=render.public_data(fixture())
        encoded=json.dumps(data)
        for forbidden in ['hidden_holdout','model_failure','secret','speakerID','partition','prediction']:
            self.assertNotIn(forbidden,encoded)
        self.assertEqual(data['items'][0]['contextText'],'Hello 世界。')
        self.assertEqual(data['items'][0]['targets'][0]['contextRange'],{'location':6,'length':2})
        bad=fixture();bad['items'][0]['targets'][1]['id']='t1'
        with self.assertRaises(ValueError):render.public_data(bad)

    def test_script_injection_is_data_and_no_network(self):
        data=render.public_data(fixture());data['items'][0]['contextText']='</script><img src=x onerror=alert(1)>\u2028'
        page=render.render(data)
        encoded=page.split('<script id="data" type="application/json">')[1].split('</script>')[0]
        self.assertEqual(json.loads(encoded),data)
        self.assertNotIn(data['items'][0]['contextText'],page)
        self.assertNotIn('innerHTML',page)
        self.assertIn("connect-src 'none'",page)

    def test_invalid_ranges_and_private_output(self):
        for mutate in [lambda b:b['items'][0].update(end=101),
                       lambda b:b['items'][0]['targets'][0].update(end=float('inf')),
                       lambda b:b['items'][0]['targets'][0].update(contextRange={'location':0,'length':2}),
                       lambda b:b['items'][0]['references'][0].update(end=101)]:
            bad=fixture();mutate(bad)
            with self.assertRaises(ValueError):render.public_data(bad)
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'review.html'
            render.write_private_text(path,'synthetic',[])
            self.assertEqual(stat.S_IMODE(path.stat().st_mode),0o600)
            with self.assertRaises(ValueError):render.write_private_text(path,'overwrite',[path])

    def test_individual_target_contract_roundtrip_and_rejection(self):
        script=r"""
const assert=require('node:assert/strict'),c=require(process.argv[1]),data=JSON.parse(process.argv[2]);
const a={targetId:'t1',decision:'reference',referenceId:'r1',flags:{referenceUnusable:true},notes:'Check the ending.'};
const b={targetId:'t2',decision:'other',otherSpeaker:'Voice C',flags:{timingWrong:true,missingWord:true}};
const output=c.export(data,{t1:a,t2:b});
assert.equal(output.labels.length,2);
for(const patch of [{audioHash:'wrong'},{track:'wrong'},{itemId:'wrong'},{flags:{timingWrong:'false'}}])assert.throws(()=>c.validate(data,{...output,labels:[{...output.labels[0],...patch}]}));assert.equal(output.labels[0].referenceId,'r1');assert.equal(output.labels[1].otherSpeaker,'Voice C');
assert.equal(output.labels[0].flags.referenceUnusable,true);assert.equal(output.labels[0].audioHash,'audiohash');
assert.ok(!JSON.stringify(output).includes('Hello'));assert.ok(!JSON.stringify(output).includes('audio.wav'));
assert.deepEqual(c.validate(data,output),output.labels);
for(const patch of [{reviewId:'other'},{inputHash:'stale'},{labels:[{...a,targetId:'missing'}]},{labels:[a,a]},{labels:[{...a,referenceId:'wrong'}]},{labels:[{...a,decision:'invented'}]},{labels:[{...a,decision:'custom_reference',referenceStart:1,referenceEnd:50}]}])assert.throws(()=>c.validate(data,{...output,...patch}));
assert.equal(c.export(data,{t1:{...a,decision:'no_speech'}}).labels[0].referenceId,null);
assert.equal(c.export(data,{t1:{...a,decision:'custom_reference',referenceStart:20,referenceEnd:25}}).labels[0].referenceEnd,25);
assert.throws(()=>c.export(data,{t1:{...a,decision:'custom_reference',referenceStart:2,referenceEnd:4}}));
assert.throws(()=>c.export(data,{t1:{...a,decision:'speech_present'}}));
data.items[0].targets[0].type='clipSpeechPresence';
assert.equal(c.export(data,{t1:{...a,decision:'speech_present'}}).labels[0].decision,'speech_present');
assert.throws(()=>c.export(data,{t1:a}));
"""
        subprocess.run(['node','-e',script,str(Path(__file__).with_name('annotation.js').resolve()),json.dumps(render.public_data(fixture()))],check=True)


if __name__=='__main__':unittest.main()
