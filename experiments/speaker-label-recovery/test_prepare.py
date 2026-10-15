"""Synthetic target, support, and partition isolation checks."""
import unittest
from prepare import acoustic_support, canonical_target, overlaps, prepare, lexical


def fixture():
    source=[];projected=[];turns=[]
    tracks={f'track{i}':{'source':name,'duration':700} for i,name in enumerate(['microphone','system'])}
    for track in tracks:
        for i in range(60):
            start=i*10;identity=f'{track}-row-{i}'
            span={'start':start+3.,'end':start+4.,'range':{'location':0,'length':1},'granularity':'word'}
            row={'id':identity,'text':'X','start':start,'end':start+9,'analysisTrackID':track,
                 'source':tracks[track]['source'],'timing':{'text':'X','spans':[span]}}
            source.append(row)
            projected.append({**row,'sourcePlaceholder':i%3!=0,'speakerID':'synthetic' if i%3==0 else None,
                              'sourceSpans':[{'rowID':identity,'text':'X','range':{'location':0,'length':1}}]})
            turns.extend([{'track':track,'label':'A','start':start,'end':start+1},
                          {'track':track,'label':'A','start':start+3 if i%2==0 else start+5,'end':start+3.2 if i%2==0 else start+6}])
    feedback={'reviews':[{'track':'track1','source':'system','start':10,'end':15,'notes':'unresolved'},
                         {'track':'track0','source':'microphone','start':20,'end':25,'notes':'noise'}]}
    return {'segments':source},projected,{'ranges':turns},feedback,tracks


class PreparationTests(unittest.TestCase):
    def test_utf16_source_and_granularity(self):
        row={'analysisTrackID':'track0','text':'😀X','sourceSpans':[{'rowID':'source','text':'😀X','range':{'location':0,'length':3}}]}
        target=canonical_target(row,{'start':1,'end':2,'range':{'location':2,'length':1},'granularity':'run'},
                                {'source':{'id':'source','text':'😀X'}})
        self.assertEqual(target['text'],'X');self.assertEqual(target['range']['location'],2)
        self.assertEqual(target['granularity'],'run')

    def test_support_is_not_timing_truth(self):
        target={'start':1,'end':2}
        value=acoustic_support(target,[{'start':.9,'end':1.2,'label':'A'}])
        self.assertEqual(value['category'],'oneSpeakerOverlap')
        self.assertFalse(value['midpointCovered']);self.assertAlmostEqual(value['coverageFraction'],.2)
        self.assertEqual(acoustic_support(target,[])['category'],'noOverlap')

    def test_partitions_and_references_are_disjoint(self):
        args=fixture();items,_=prepare(*args,heldout_count=4)
        dev=[i for i in items if i['partition']=='development'];held=[i for i in items if i['partition']=='heldout']
        self.assertEqual(len(held),8)
        prior={track:[(r['start'],r['end']) for r in args[3]['reviews'] if r['track']==track] for track in args[4]}
        for item in dev:
            prior[item['track']]+=[(item['start'],item['end'])]+[(r['start'],r['end']) for r in item['references']]
        for item in held:
            own=[(item['start'],item['end'])]+[(r['start'],r['end']) for r in item['references']]
            self.assertTrue(item['references'])
            for a,b in own:
                self.assertFalse(any(overlaps(a,b,c,d) for c,d in prior[item['track']]))
            prior[item['track']]+=own
        self.assertEqual(len({t['id'] for i in items for t in i['targets']}),sum(len(i['targets']) for i in items))

    def test_decoration_retained_in_diagnostics_not_questions(self):
        args=fixture()
        for row in args[0]['segments']:
            if row['id']=='track1-row-1':row['text']='.';row['timing']['text']='.'
        for row in args[1]:
            if row['id']=='track1-row-1':
                row['text']='.';row['timing']['text']='.';row['sourceSpans'][0]['text']='.'
        items,diagnostics=prepare(*args,heldout_count=4)
        self.assertEqual(diagnostics['flaggedDecorationTargets'],1)
        self.assertTrue(all(lexical(t) for item in items for t in item['targets']))

    def test_duplicate_source_and_out_of_bounds_fail(self):
        args=fixture();args[0]['segments'].append(args[0]['segments'][0])
        with self.assertRaises(ValueError):prepare(*args,heldout_count=4)
        args=fixture();args[0]['segments'][0]['timing']['spans'][0]['end']=900
        with self.assertRaises(ValueError):prepare(*args,heldout_count=4)


if __name__=='__main__':unittest.main()
