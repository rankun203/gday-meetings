"""Correlate saved labeling state transitions with recorded PCM, without causal claims."""
import argparse
import hashlib
import json
from pathlib import Path
import wave
import numpy as np


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--journal', type=Path, required=True)
    p.add_argument('--audio', type=Path, required=True)
    p.add_argument('--fresh-evidence', type=Path, required=True)
    p.add_argument('--source', choices=['microphone', 'system'], required=True)
    p.add_argument('--route-change', type=float)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    windows = {}; gaps = []
    for line in a.journal.open():
        record = json.loads(line)
        w = record.get('window')
        if w and w['source'] == a.source: windows[w['generation']] = w
        g = record.get('gap')
        if g and g['source'] == a.source: gaps.append(g)
    ordered = sorted(windows.values(), key=lambda w: w['publicationStart'])
    fresh = json.loads(a.fresh_evidence.read_text())
    with wave.open(str(a.audio)) as f:
        if f.getnchannels() != 1 or f.getsampwidth() != 2:
            raise ValueError('Requires receipt-bound mono PCM16 WAV')
        rate = f.getframerate()
        pcm = np.frombuffer(f.readframes(f.getnframes()), dtype='<i2').astype(np.float64)/32768
    rows = []
    for start in range(0, int(len(pcm)/rate)+1, 10):
        end = min(start+10, len(pcm)/rate); samples = pcm[int(start*rate):int(end*rate)]
        if not len(samples): continue
        rows.append(dict(start=start, end=end,
                         rmsDBFS=float(20*np.log10(max(np.sqrt(np.mean(samples*samples)), 1e-12))),
                         peakDBFS=float(20*np.log10(max(np.max(np.abs(samples)), 1e-12))),
                         stateStarts=sum(start <= w['publicationStart'] < end for w in ordered),
                         gapRecords=sum(g['start'] < end and g['end'] > start for g in gaps),
                         freshReportedSpeakerSeconds=sum(max(0, min(end,x['end'])-max(start,x['start'])) for x in fresh['activity']),
                         freshSamples=sum(start <= x['end'] < end for x in fresh['samples'])))
    result = dict(source=a.source, bins=rows, windowCount=len(ordered),
                  capacityReachedWindows=sum('capacityReachedAt' in w for w in ordered),
                  limitations=['Fresh serial inference differs in scheduling and policy from live capture.',
                               'Recorded loudness cannot prove AGC causation.',
                               'Label-processing gaps are not proof of missing recorded PCM.'],
                  inputSHA256={str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                               for path in [a.journal,a.audio,a.fresh_evidence,Path(__file__)]})
    if a.route_change is not None:
        later = [w for w in ordered if w['publicationStart'] >= a.route_change]
        result['routeChangeSeconds'] = a.route_change
        result['firstTenWindowsAfterRoute'] = [{k:v for k,v in w.items() if k != 'localSpeakerIDs'} for w in later[:10]]
    a.output.parent.mkdir(parents=True, exist_ok=True)
    with a.output.open('x') as f: json.dump(result,f,indent=2)

if __name__ == '__main__': main()
