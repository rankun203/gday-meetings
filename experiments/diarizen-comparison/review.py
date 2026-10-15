"""Generate an offline listening review. Private text/audio remain in ignored output."""
import argparse
import html
import json
import math
import os
from pathlib import Path


def load_rows(path):
    text = Path(path).read_text()
    if text.lstrip().startswith('['):
        return json.loads(text)
    return [json.loads(line) for line in text.splitlines() if line.strip()]


def window_scores(candidates, track, duration, size=30):
    """Rank activity/count disagreement, not arbitrary speaker-label disagreement."""
    scored = []
    for start in range(0, math.ceil(duration), size):
        end = min(start + size, duration)
        activity = []
        for candidate in candidates:
            turns = [r for r in candidate['ranges'] if r['track'] == track]
            samples = []
            for tick in range(math.ceil(start * 2), math.ceil(end * 2)):
                t = tick / 2 + .25
                samples.append(len({r['label'] for r in turns if r['start'] <= t < r['end']}))
            boundaries = sum(start <= r['start'] < end for r in turns)
            activity.append((samples, boundaries))
        score = 0.
        if len(activity) >= 2:
            first = activity[0]
            for other in activity[1:]:
                score += sum(abs(a - b) for a, b in zip(first[0], other[0])) * .5
                score += abs(first[1] - other[1]) * .25
        scored.append({'track': track, 'start': start, 'end': end, 'score': score})
    return sorted(scored, key=lambda row: (-row['score'], row['start']))


def build(inputs, results, output, projected=None, per_track=6):
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    manifest = json.loads(Path(inputs).read_text())
    candidates = []
    for item in json.loads(Path(results).read_text()):
        result = json.loads(Path(item['path']).read_text())
        candidate = {'name': item['name'], 'ranges': result['ranges'], 'rows': []}
        if projected and item['name'] in projected:
            candidate['rows'] = load_rows(projected[item['name']])
        candidates.append(candidate)
    tracks = []
    windows = []
    for track in manifest['tracks']:
        tracks.append({'id': track['track'], 'source': track['source'], 'duration': track['duration'],
                       'audio': os.path.relpath(track['path'], output.parent)})
        windows.extend(window_scores(candidates, track['track'], track['duration'])[:per_track])
    payload = json.dumps({'tracks': tracks, 'candidates': candidates, 'windows': windows}, ensure_ascii=True)
    payload = payload.replace('<', '\\u003c').replace('>', '\\u003e').replace('&', '\\u0026')
    document = TEMPLATE.replace('/*PAYLOAD*/', payload)
    output.write_text(document)
    return len(windows)


TEMPLATE = '''<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; media-src 'self' file:;">
<title>Diarization Listening Review</title>
<style>
:root{color-scheme:light dark;font:15px system-ui}body{max-width:1100px;margin:32px auto;padding:0 20px}
h1{font-size:27px}p{line-height:1.5}.note{color:light-dark(#555,#bbb)}button,select{font:inherit;padding:6px 10px}button{cursor:pointer}
.toolbar{display:flex;gap:10px;align-items:center;flex-wrap:wrap}audio{width:min(100%,620px);margin:16px 0}
section{border:1px solid light-dark(#ddd,#555);border-radius:10px;padding:16px;margin:16px 0}h2{font-size:18px;margin:0 0 12px}
.timeline{position:relative;overflow-x:auto}svg{display:block;min-width:650px;width:100%}svg text{fill:currentColor;font-size:12px}
.cursor{stroke:light-dark(#111,#fff);stroke-width:2}.rows{max-height:240px;overflow:auto}.row{padding:8px 0;border-bottom:1px solid light-dark(#eee,#444)}
small{color:light-dark(#555,#bbb)}.pill{padding:2px 6px;border-radius:5px;background:light-dark(#eee,#333);margin-right:8px}
</style>
<h1>Diarization Listening Review</h1>
<p>Compare automatic speaker turns against the same audio. Speaker labels are scoped to each engine and track; equal labels do not identify the same person.</p>
<p class="note">Windows are ranked by differences in detected speech, simultaneous speaker counts, and turn counts. Ranking does not establish which engine is correct. No reference labels or diarization error rate are available.</p>
<div class="toolbar"><label>Window <select id="window"></select></label><button id="play">Play Window</button><button id="stop">Pause</button></div>
<audio id="audio" controls preload="metadata"></audio><p id="status" class="note"></p><main id="engines"></main>
<script>
const data=/*PAYLOAD*/;
const select=document.querySelector('#window'),audio=document.querySelector('#audio'),main=document.querySelector('#engines');
const colors=['#0072b2','#d55e00','#009e73','#cc79a7','#a6761d','#56b4e9','#777777'];let selected;
function text(tag,value,parent){const el=document.createElement(tag);el.textContent=value;parent.append(el);return el;}
function time(t){return Math.floor(t/60)+':'+String(Math.floor(t%60)).padStart(2,'0');}
for(const [i,w] of data.windows.entries()){const track=data.tracks.find(t=>t.id===w.track);const o=document.createElement('option');o.value=i;o.textContent=track.source+' · '+time(w.start)+'–'+time(w.end)+' · activity difference '+w.score.toFixed(1);select.append(o);}
function svgEl(tag,attrs,parent){const el=document.createElementNS('http://www.w3.org/2000/svg',tag);for(const [k,v]of Object.entries(attrs))el.setAttribute(k,v);parent.append(el);return el;}
function render(){selected=data.windows[Number(select.value)];if(!selected)return;audio.pause();const track=data.tracks.find(t=>t.id===selected.track);audio.src=track.audio;audio.currentTime=selected.start;main.replaceChildren();
 for(const candidate of data.candidates){const section=document.createElement('section');main.append(section);text('h2',candidate.name,section);const turns=candidate.ranges.filter(r=>r.track===selected.track&&r.start<selected.end&&r.end>selected.start);const speakers=[...new Set(turns.map(r=>r.label))].sort();const box=document.createElement('div');box.className='timeline';section.append(box);const width=1000,left=115,span=width-left-10;const svg=svgEl('svg',{viewBox:'0 0 '+width+' '+Math.max(65,30+speakers.length*30),role:'img','aria-label':'Automatic speaker turns'},box);const x=t=>left+(t-selected.start)/(selected.end-selected.start)*span;
 for(let i=0;i<=6;i++){const t=selected.start+(selected.end-selected.start)*i/6;svgEl('line',{x1:x(t),x2:x(t),y1:20,y2:30+speakers.length*30,stroke:'#888','stroke-opacity':'.2'},svg);svgEl('text',{x:x(t),y:13,'text-anchor':i===6?'end':'start'},svg).textContent=time(t);}
 speakers.forEach((s,i)=>{svgEl('text',{x:0,y:43+i*30},svg).textContent='Speaker '+s;for(const r of turns.filter(r=>r.label===s)){const rect=svgEl('rect',{x:x(Math.max(r.start,selected.start)),y:27+i*30,width:Math.max(1,x(Math.min(r.end,selected.end))-x(Math.max(r.start,selected.start))),height:22,rx:3,fill:colors[i%colors.length]},svg);svgEl('title',{},rect).textContent='Speaker '+s+' '+r.start.toFixed(2)+'–'+r.end.toFixed(2);}});svgEl('line',{x1:left,x2:left,y1:20,y2:30+speakers.length*30,class:'cursor'},svg);
 if(!speakers.length)text('p','No speech detected in this window.',section);
 const rows=candidate.rows.filter(r=>(r.analysisTrackID===selected.track||(r.analysisTrackID==null&&r.source===track.source))&&r.start<selected.end&&r.end>selected.start);if(rows.length){const list=document.createElement('div');list.className='rows';section.append(list);for(const r of rows){const item=document.createElement('div');item.className='row';list.append(item);text('small',time(r.start)+' ',item);const label=text('span',(r.sourcePlaceholder||!r.speakerID)?'Automatic · unresolved':'Automatic · '+(r.speaker||'Speaker'),item);label.className='pill';text('span',r.text,item);}}else text('p','Projected transcript unavailable for this engine/window.',section);
 }
 document.querySelector('#status').textContent=track.source+' · '+time(selected.start)+'–'+time(selected.end)+'. Play the same window while comparing both timelines.';
}
select.onchange=render;document.querySelector('#play').onclick=()=>{audio.currentTime=selected.start;audio.play().catch(()=>{document.querySelector('#status').textContent='Couldn’t play this audio. Keep the review page beside its local audio folder and check that the WAV file is available.';});};document.querySelector('#stop').onclick=()=>audio.pause();audio.onerror=()=>{document.querySelector('#status').textContent='Couldn’t load this audio. Check the local WAV file and reopen the review page.';};audio.ontimeupdate=()=>{if(audio.currentTime>=selected.end)audio.pause();const ratio=Math.max(0,Math.min(1,(audio.currentTime-selected.start)/(selected.end-selected.start)));document.querySelectorAll('.cursor').forEach(el=>{el.setAttribute('x1',115+ratio*875);el.setAttribute('x2',115+ratio*875);});};render();
</script></html>'''

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--inputs', type=Path, required=True)
    parser.add_argument('--results', type=Path, required=True)
    parser.add_argument('--projected', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--per-track', type=int, default=6)
    args = parser.parse_args()
    projected = json.loads(args.projected.read_text()) if args.projected else None
    print(json.dumps({'review_windows': build(args.inputs, args.results, args.output, projected, args.per_track)}))
