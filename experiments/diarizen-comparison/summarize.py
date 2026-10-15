"""Aggregate acoustic coverage; these metrics are not diarization accuracy."""
import argparse
import json
from collections import Counter, defaultdict
from pathlib import Path


def summarize(ranges):
    tracks = defaultdict(list)
    for item in ranges:
        tracks[item['track']].append(item)
    results = {}
    for track, turns in tracks.items():
        events = []
        for turn in turns:
            events.extend([(turn['start'], 1, turn['label']), (turn['end'], -1, turn['label'])])
        events.sort()
        active, previous, speech, overlap = Counter(), 0., 0., 0.
        for timestamp, change, speaker in events:
            if len(active) > 0:
                speech += timestamp - previous
            if len(active) > 1:
                overlap += timestamp - previous
            active[speaker] += change
            if active[speaker] == 0:
                del active[speaker]
            previous = timestamp
        results[track] = {'speakers': len({t['label'] for t in turns}), 'turns': len(turns),
                         'speech_union_seconds': speech, 'overlap_seconds': overlap}
    return results

if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('results', type=Path, nargs='+')
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    values = {f'candidate{index}': summarize(json.loads(path.read_text())['ranges'])
              for index, path in enumerate(a.results)}
    a.output.write_text(json.dumps(values, indent=2))
    print(json.dumps(values, indent=2))
