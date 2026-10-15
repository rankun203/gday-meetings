"""Compare identical support with existing mappings and verify projection text conservation."""
import argparse
from collections import Counter, defaultdict
import importlib.util
import json
from pathlib import Path
from run import ROOT


def fixed_support(local, remote, mappings):
    events = defaultdict(list)
    for side, values in enumerate([*local, remote]):
        for start, end, label in values:
            events[start].append((side, label, 1))
            events[end].append((side, label, -1))
    states = [Counter() for _ in range(3)]
    previous, duration, matched = None, 0., [0., 0.]
    for timestamp in sorted(events):
        if previous is not None and all(len(s) == 1 and None not in s for s in states):
            delta = timestamp - previous
            duration += delta
            reference = next(iter(states[2]))
            for side in range(2):
                if mappings[side].get(next(iter(states[side]))) == reference: matched[side] += delta
        for side, label, change in events[timestamp]:
            states[side][label] += change
            if not states[side][label]: del states[side][label]
        previous = timestamp
    return {'commonSeconds': duration, 'mapping': 'Existing global mappings held fixed',
            'baselineMatchedSeconds': matched[0], 'denseMatchedSeconds': matched[1],
            'baselineDisagreementSeconds': duration-matched[0], 'denseDisagreementSeconds': duration-matched[1],
            'baselineAgreement': matched[0]/duration if duration else None,
            'denseAgreement': matched[1]/duration if duration else None}


def conservation(source, projected):
    original = {r['id']: r['text'].encode('utf-16-le') for r in source}
    intervals = defaultdict(list)
    for row in projected:
        anchors = row.get('sourceSpans', [])
        assert anchors and ''.join(a.get('separatorBefore', '')+a['text'] for a in anchors) == row['text']
        for anchor in anchors:
            begin = anchor['range']['location']
            end = begin+anchor['range']['length']
            assert original[anchor['rowID']][begin*2:end*2].decode('utf-16-le') == anchor['text']
            intervals[anchor['rowID']].append((begin,end))
    for identity, text in original.items():
        previous = 0
        for begin,end in sorted(intervals[identity]):
            assert begin == previous and end >= begin
            previous = end
        assert previous == len(text)//2
    return {'sourceRows': len(source), 'sourceUTF16Units': sum(len(t)//2 for t in original.values()),
            'preservedExactlyOnce': True}


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--run', type=Path, required=True)
    p.add_argument('--remote', type=Path, required=True)
    a = p.parse_args()
    root = a.run.resolve()
    assert root.is_relative_to(ROOT/'.local')
    spec = importlib.util.spec_from_file_location('comparison', ROOT.parent/'runpod-output-comparison/compare.py')
    comparison = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(comparison)
    tracks = json.loads((root/'inputs.json').read_text())['tracks']
    source = [json.loads(s) for s in (root/'immutable-source.jsonl').read_text().splitlines()]
    profiles = ['baseline','dense']
    rows = [[json.loads(s) for s in (root/'projections'/f'{name}-transcript.jsonl').read_text().splitlines()] for name in profiles]
    local = [comparison.normalize_local(value, tracks)[0] for value in rows]
    remote = comparison.normalize_remote(json.loads(a.remote.read_text()), tracks)[0]
    agreements = [json.loads((root/f'{name}-agreement.json').read_text()) for name in profiles]
    report = {'textConservation': {name:conservation(source, value) for name,value in zip(profiles,rows)}, 'tracks': {}}
    for track in tracks:
        name = track['track']
        mappings = [r['tracks'][name]['local_to_remote_speaker_mapping'] for r in agreements]
        report['tracks'][name] = fixed_support([value[name] for value in local], remote[name], mappings)
    (root/'fixed-common-support.json').write_text(json.dumps(report,indent=2))
    print(json.dumps(report,indent=2))


if __name__ == '__main__': main()
