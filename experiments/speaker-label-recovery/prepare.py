"""Prepare a private annotation batch from immutable text, saved turns, and prior feedback."""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
import math
from pathlib import Path


def sha(path):
    with Path(path).open('rb') as stream: return hashlib.file_digest(stream, 'sha256').hexdigest()


def identifier(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()[:20]


def utf16(text): return len(text.encode('utf-16-le')) // 2


def slice_text(text, location, length):
    return text.encode('utf-16-le')[location*2:(location+length)*2].decode('utf-16-le')


def lexical(target): return target.get('type')=='clipSpeechPresence' or any(c.isalnum() for c in target.get('text',''))


def overlaps(start, end, other_start, other_end): return start < other_end and end > other_start


def canonical_target(row, span, original):
    cursor = 0
    for anchor in row.get('sourceSpans', []):
        cursor += utf16(anchor.get('separatorBefore', ''))
        start, length = span['range']['location'], span['range']['length']
        if cursor <= start and start+length <= cursor+utf16(anchor['text']):
            source = original[anchor['rowID']]
            location = anchor['range']['location']+start-cursor
            text = slice_text(source['text'], location, length)
            assert text == slice_text(row['text'], start, length)
            value = {'type':'timedText','track':row['analysisTrackID'],'text':text,
                     'start':span['start'],'end':span['end'],'sourceRowID':source['id'],
                     'range':{'location':location,'length':length},'granularity':span.get('granularity','unknown')}
            value['id'] = identifier(value)
            return value
        cursor += utf16(anchor['text'])
    raise ValueError('Projected timing span has no exact immutable source anchor')


def acoustic_support(target, turns):
    start,end = target['start'],target['end']
    relevant = [t for t in turns if overlaps(start,end,t['start'],t['end'])]
    labels = {t['label'] for t in relevant}
    intervals = sorted((max(start,t['start']),min(end,t['end'])) for t in relevant)
    union,last = 0.,start
    for left,right in intervals:
        union += max(0,right-max(last,left));last=max(last,right)
    midpoint=(start+end)/2
    midpoint_labels={t['label'] for t in relevant if t['start'] <= midpoint < t['end']}
    preceding=[t for t in turns if t['end']<=start]
    following=[t for t in turns if t['start']>=end]
    return {'category':'noOverlap' if not relevant else 'oneSpeakerOverlap' if len(labels)==1 else 'multipleSpeakerOverlap',
            'overlapSeconds':union,'coverageFraction':union/(end-start) if end>start else 0,
            'midpointCovered':bool(midpoint_labels),'distinctSpeakers':len(labels),
            'precedingGapSeconds':start-max(t['end'] for t in preceding) if preceding else None,
            'followingGapSeconds':min(t['start'] for t in following)-end if following else None}


def blocked(start,end,intervals,padding=0):
    return any(overlaps(start-padding,end+padding,a,b) for a,b in intervals)


def references(targets, turns, exclusions=()):
    start=min(t['start'] for t in targets);end=max(t['end'] for t in targets)
    choices=[]
    for relation,candidates in [('previous',sorted([t for t in turns if t['end']<=start and start-t['end']<=25],key=lambda t:-t['end'])),
                                ('next',sorted([t for t in turns if t['start']>=end and t['start']-end<=25],key=lambda t:t['start']))]:
        for turn in candidates:
            a,b=(max(turn['start'],turn['end']-3),turn['end']) if relation=='previous' else (turn['start'],min(turn['end'],turn['start']+3))
            if b-a<.35 or blocked(a,b,exclusions): continue
            choices.append({'id':identifier([relation,a,b]),'label':'Reference '+('A' if not choices else 'B'),
                            'start':a,'end':b,'relation':relation})
            break
    return choices


def context(targets, original):
    sources=sorted({t['sourceRowID'] for t in targets if t.get('sourceRowID')},key=lambda k:original[k]['start'])
    pieces=[];offsets={};offset=0
    for key in sources:
        if pieces:offset+=1
        offsets[key]=offset;pieces.append(original[key]['text']);offset+=utf16(pieces[-1])
    for target in targets:
        if target.get('sourceRowID'):
            target['contextRange']={'location':offsets[target['sourceRowID']]+target['range']['location'],'length':target['range']['length']}
    return '\n'.join(pieces)


def prepare(source, projected, raw, feedback, tracks, heldout_count=12):
    original={r['id']:r for r in source['segments']}
    if len(original)!=len(source['segments']):raise ValueError('Duplicate immutable source row IDs')
    for row in source['segments']:
        if row.get('analysisTrackID') not in tracks or row.get('source')!=tracks[row['analysisTrackID']]['source']:raise ValueError('Source row track does not match input')
        if row.get('timing',{}).get('text')!=row['text']:raise ValueError('Source text timing is stale')
        for span in row['timing']['spans']:
            if not (math.isfinite(span['start']) and math.isfinite(span['end']) and 0<=span['start']<span['end']<=tracks[row['analysisTrackID']]['duration']+.02):raise ValueError('Source timing outside audio')
            if not (row['start']-.02<=span['start'] and span['end']<=row['end']+.02):raise ValueError('Timed span outside source row')
            if not (0<=span['range']['location'] and span['range']['length']>0 and span['range']['location']+span['range']['length']<=utf16(row['text'])):raise ValueError('Source text range invalid')
    for turn in raw['ranges']:
        if turn.get('track') not in tracks or not (math.isfinite(turn['start']) and math.isfinite(turn['end']) and 0<=turn['start']<turn['end']<=tracks[turn['track']]['duration']+.02):raise ValueError('Acoustic turn outside input')
    turns={track:sorted([r for r in raw['ranges'] if r['track']==track],key=lambda r:r['start']) for track in tracks}
    unresolved=[];resolved=[];all_ids=set()
    for row in projected:
        for span in row.get('timing',{}).get('spans',[]):
            target=canonical_target(row,span,original)
            target['diagnostic']=acoustic_support(target,turns[target['track']])
            if target['id'] in all_ids:raise ValueError('Duplicate projected target anchors')
            all_ids.add(target['id'])
            (resolved if row.get('speakerID') and not row.get('sourcePlaceholder') else unresolved).append(target)
    reviewed=defaultdict(list)
    for review in feedback['reviews']:reviewed[review['track']].append((review['start'],review['end']))
    items=[];seen=set();target_diagnostics={};flagged_all=[];decoration_targets=[]
    def append_item(track,start,end,partition,category,targets,exclude_refs=()):
        targets=[dict(t) for t in targets]
        for t in targets:
            if 'diagnostic' in t:target_diagnostics[t['id']]=t.pop('diagnostic')
            if not lexical(t):decoration_targets.append(t)
        targets=[t for t in targets if lexical(t)]
        if not targets:return None
        item={'id':identifier([track,start,end,partition,category]),'track':track,'start':start,'end':end,
              'partition':partition,'category':category,'targets':targets,'contextText':context(targets,original),
              'references':references(targets,turns[track],exclude_refs)}
        items.append(item)
        return item
    for review in feedback['reviews']:
        if review['source']=='system' and 'unresolved' in review.get('notes','').lower():
            targets=[t for t in unresolved if t['track']==review['track'] and overlaps(t['start'],t['end'],review['start'],review['end']) and t['id'] not in seen]
            if targets:
                flagged_all.extend(targets)
                append_item(review['track'],min(review['start'],min(t['start'] for t in targets)),max(review['end'],max(t['end'] for t in targets)),
                            'development','flaggedUnresolved',targets)
                seen.update(t['id'] for t in targets)
    for review in feedback['reviews']:
        if review['source']=='microphone' and 'noise' in review.get('notes','').lower():
            target={'id':identifier(['speechPresence',review['track'],review['start'],review['end']]),'type':'clipSpeechPresence',
                    'text':'','start':review['start'],'end':review['end']}
            append_item(review['track'],review['start'],review['end'],'development','noiseControl',[target])
    # Hold out fresh intervals of the same failure classes, balanced across source and support class.
    exclusions={track:list(reviewed[track]) for track in tracks}
    for item in items:
        exclusions[item['track']].append((item['start'],item['end']))
        exclusions[item['track']]+=[(r['start'],r['end']) for r in item['references']]
    candidates=defaultdict(list)
    for target in unresolved:
        if lexical(target) and target['diagnostic']['category'] in ['noOverlap','oneSpeakerOverlap']:
            candidates[(target['track'],target['diagnostic']['category'])].append(target)
    # A fixed hash order avoids choosing the most persuasive examples.
    for values in candidates.values():values.sort(key=lambda t:identifier(['heldout-v1',t['id']]))
    keys=sorted(candidates)
    count=0
    while count<heldout_count:
        added=False
        for key in keys:
            track,category=key
            while candidates[key]:
                target=candidates[key].pop(0)
                start=max(0,target['start']-4);end=min(tracks[track]['duration'],target['end']+4)
                if blocked(start,end,exclusions[track],padding=1):continue
                nearby=[t for t in unresolved if t['track']==track and t['diagnostic']['category']==category and lexical(t) and start<=t['start'] and t['end']<=end]
                # Limit fresh annotation burden; known flagged clips retain every target.
                chosen=sorted(nearby,key=lambda t:abs(t['start']-target['start']))[:3]
                item=append_item(track,start,end,'heldout',category,sorted(chosen,key=lambda t:t['start']),exclusions[track])
                exclusions[track].append((start,end));exclusions[track]+=[(r['start'],r['end']) for r in item['references']]
                count+=1;added=True;break
            if count>=heldout_count:break
        if not added:break
    if count!=heldout_count:raise ValueError('Insufficient disjoint held-out clips; review selection rather than silently shrinking it')
    # Fresh previously assigned controls detect regressions; their automatic labels are not truth.
    for track in sorted(tracks):
        values=sorted([t for t in resolved if t['track']==track and t['granularity']=='word' and lexical(t)],key=lambda t:identifier(['assigned-control-v1',t['id']]))
        selected=0
        for target in values:
            start=max(0,target['start']-4);end=min(tracks[track]['duration'],target['end']+4)
            if blocked(start,end,exclusions[track],padding=1):continue
            if not references([target],turns[track],exclusions[track]):continue
            item=append_item(track,start,end,'heldout','previouslyAssignedControl',[target],exclusions[track])
            exclusions[track].append((start,end));exclusions[track]+=[(r['start'],r['end']) for r in item['references']]
            selected+=1
            if selected==2:break
        if selected!=2:raise ValueError('Insufficient fresh assigned controls')
    # Mix partitions without exposing the split in item sequence.
    items.sort(key=lambda i:identifier(['presentation-v1',i['id']]))
    diagnostics={'flaggedTargets':dict(Counter(t['diagnostic']['category'] for t in flagged_all)),
                 'flaggedLexicalTargets':sum(lexical(t) for t in flagged_all),'flaggedDecorationTargets':sum(not lexical(t) for t in flagged_all),'decorationTargets':decoration_targets,
                 'items':len(items),'targets':sum(len(i['targets']) for i in items),'partitions':dict(Counter(i['partition'] for i in items)),
                 'targetDiagnostics':target_diagnostics,'priorReviewedIntervals':dict(reviewed),
                 'evidenceLimit':'Final turns cannot identify segmentation, embedding, clustering, or reconstruction causes. No preclustering arrays were saved. Speech-active zero-vote frames already tie-break to cluster 0; re-embedding can change identity, not necessarily recover missing coverage.'}
    return items,diagnostics


def main():
    p=argparse.ArgumentParser()
    for name in ['source','projected','raw','feedback','audio','original-audio-state','output']:p.add_argument('--'+name,type=Path,required=True)
    a=p.parse_args();root=Path(__file__).resolve().parent
    output=a.output.resolve()
    if not output.is_relative_to(root/'.local'):p.error('Write private artifacts under this experiment’s .local directory.')
    source=json.loads(a.source.read_text());projected=[json.loads(l) for l in a.projected.read_text().splitlines() if l.strip()]
    raw=json.loads(a.raw.read_text());feedback=json.loads(a.feedback.read_text());audio=json.loads(a.audio.read_text())
    tracks={t['track']:{'source':t['source'],'audio':t['path'],'sha256':t['sha256'],'duration':t['duration']} for t in audio['tracks']}
    for t in tracks.values():assert sha(t['audio'])==t['sha256']
    original_audio=json.loads(a.original_audio_state.read_text())['tracks']
    for track in original_audio:
        if sha(a.original_audio_state.parent/track['file'])!=track['sha256']:raise ValueError('Original audio bytes do not match manifest')
    original_hashes={t['track']:t['sha256'] for t in original_audio}
    for review in feedback['reviews']:
        if review['audioHash']!=original_hashes.get(review['track']):raise ValueError('Feedback audio hash does not match original source')
    for track in tracks:tracks[track]['originalSHA256']=original_hashes[track]
    items,diagnostics=prepare(source,projected,raw,feedback,tracks)
    hashes={name:sha(getattr(a,name)) for name in ['source','projected','raw','feedback','audio','original_audio_state']}
    fingerprint=hashlib.sha256(json.dumps({'inputs':hashes,'items':items},sort_keys=True).encode()).hexdigest()
    data={'version':1,'reviewId':fingerprint[:24],'inputHash':fingerprint,'tracks':tracks,'items':items}
    diagnostics['inputHashes']=hashes;diagnostics['inputHash']=fingerprint
    output.mkdir(parents=True,exist_ok=True)
    for name,value in [('annotation-data.json',data),('diagnostics.json',diagnostics)]:
        path=output/name;path.write_text(json.dumps(value,ensure_ascii=False,indent=2));path.chmod(0o600)
    print(json.dumps({k:diagnostics[k] for k in ['flaggedTargets','items','targets','partitions']}))


if __name__=='__main__':main()
