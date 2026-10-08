"""Create private playable review material; selections are not accuracy labels."""
import argparse
import hashlib
import html
import json
from pathlib import Path
import random
import subprocess
import sys


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--manifest', type=Path, required=True)
    p.add_argument('--sample', required=True)
    p.add_argument('--evidence', type=Path, required=True)
    p.add_argument('--publication', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--saved-provider', type=Path)
    a = p.parse_args()
    item = next(x for x in json.loads(a.manifest.read_text())['samples'] if x['id'] == a.sample)
    evidence = json.loads(a.evidence.read_text()); publication = json.loads(a.publication.read_text())
    if hashlib.sha256(Path(item['audioPath']).read_bytes()).hexdigest() != item['audioSHA256']:
        raise ValueError('Audio input changed')
    a.output.mkdir(parents=True, exist_ok=False)
    selections = []
    def add(reason, time):
        start = max(0, min(time-4, item['durationSeconds']-12))
        selections.append(dict(reason=reason, start=start, end=min(item['durationSeconds'], start+12)))
    for w in evidence['windows']:
        if 'capacityReachedAt' in w: add('Eighth established channel boundary', w['capacityReachedAt'])
        if w['publicationStart'] > 0: add('Window handoff', w['publicationStart'])
    capacity = min((w['capacityReachedAt'] for w in evidence['windows'] if 'capacityReachedAt' in w), default=float('inf'))
    seen = set()
    for row in sorted(publication['intervals'], key=lambda x: x['start']):
        if row['speaker'] not in seen and row['start'] >= capacity and not row['speaker'].startswith('unresolved:'):
            add('First newly observed anonymous identity after capacity', row['start']); break
        seen.add(row['speaker'])
    uncertain = next((r for r in publication['intervals'] if r.get('isProvisional') or r['speaker'].startswith('unresolved:')), None)
    if uncertain: add('Uncertain or unresolved assignment', uncertain['start'])
    active = []
    for row in sorted(evidence['activity'], key=lambda x: x['start']):
        active = [r for r in active if r['end'] > row['start']]
        if any(r['localSpeakerID'] != row['localSpeakerID'] for r in active):
            add('Model-reported simultaneous local activity', row['start']); break
        active.append(row)
    rng = random.Random('speaker-review-v1:' + a.sample)
    for _ in range(3): add('Fixed-seed random audio time (not filtered by detected speech)', rng.uniform(0, item['durationSeconds']))
    if a.saved_provider:
        reference = json.loads(a.saved_provider.read_text())
        if (reference['sourceAudioSHA256'] != item['sourceAudioSHA256']
                or hashlib.sha256(Path(reference['originalExtractionPath']).read_bytes()).hexdigest() != reference['originalExtractionSHA256']):
            raise ValueError('Saved provider provenance differs')
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'diarization-benchmark'))
        from compare_reference import compare
        comparison = compare(reference['intervals'], publication['intervals'], item['durationSeconds'],
                             coverage=[dict(start=0, end=item['durationSeconds'])])
        for row in comparison['review_intervals'][:3]:
            add('Saved automatic provider disagreement (neither output is human truth)', row['start'])
    cards = []
    for i, row in enumerate(selections):
        clip = a.output / f'{i+1:02}.wav'
        subprocess.run(['ffmpeg', '-v', 'error', '-ss', str(row['start']), '-i', item['audioPath'], '-t', str(row['end']-row['start']), '-c:a', 'pcm_s16le', str(clip)], check=True)
        row['audioPath'] = str(clip.resolve())
        cards.append(f'<article><h3>{html.escape(row["reason"])}</h3><p>{row["start"]:.2f}–{row["end"]:.2f} seconds</p><audio controls src="{clip.name}"></audio></article>')
    result = dict(sample=a.sample, actualSource=item['actualSource'], selections=selections,
                  limitation='Targeted and random review clips, not reviewed truth or full-meeting DER. Provider disagreement clips are separately generated when a bound provider reference exists.',
                  inputSHA256={str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in [a.manifest, a.evidence, a.publication, Path(__file__)]})
    if a.saved_provider:
        result['inputSHA256'][str(a.saved_provider)] = hashlib.sha256(a.saved_provider.read_bytes()).hexdigest()
    (a.output/'review.json').write_text(json.dumps(result, indent=2))
    (a.output/'index.html').write_text('<!doctype html><meta charset="utf-8"><title>Speaker review</title><style>body{font:16px system-ui;max-width:800px;margin:40px auto}article{border-top:1px solid #ccc;padding:16px 0}audio{width:100%}</style><h1>'+html.escape(a.sample)+'</h1><p>Listen and annotate; these examples are not accuracy labels.</p>'+''.join(cards))

if __name__ == '__main__': main()
