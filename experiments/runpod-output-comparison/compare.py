#!/usr/bin/env python3
"""Compare final aligned speaker labels, not raw acoustic turns or ground truth."""
import argparse
from collections import Counter, defaultdict
import json
import math
import os
import tempfile
from pathlib import Path


def interval(start, end, speaker):
    if not isinstance(start, (int, float)) or not isinstance(end, (int, float)):
        return None
    if not math.isfinite(start) or not math.isfinite(end) or start < 0 or end <= start:
        return None
    label = str(speaker).strip() if speaker is not None else ''
    return (float(start), float(end), label or None)


def normalize_local(rows, tracks):
    sources = {t['source']: t['track'] for t in tracks}
    known = {t['track'] for t in tracks}
    output = defaultdict(list)
    excluded = Counter()
    for row in rows:
        track = row.get('analysisTrackID') or sources.get(row.get('source'))
        if track not in known:
            raise ValueError('Local row has no matching source track.')
        timing = row.get('timing')
        if not timing or timing.get('text') != row.get('text'):
            excluded['rows_without_current_timing'] += 1
            continue
        speaker = None if row.get('sourcePlaceholder') else row.get('speakerID')
        for span in timing.get('spans', []):
            item = interval(span.get('start'), span.get('end'), speaker)
            if item is None:
                excluded['invalid_timed_spans'] += 1
            else:
                output[track].append(item)
    return output, dict(excluded)


def normalize_remote(response, tracks):
    if response.get('status') != 'COMPLETED':
        raise ValueError('Expected a completed deployed-worker response.')
    payload = response['output']['tracks']
    known = {t['track'] for t in tracks}
    if set(payload) != known:
        raise ValueError('Remote tracks do not match the copied audio manifest.')
    output = defaultdict(list)
    excluded = Counter()
    for track, value in payload.items():
        for segment in value.get('segments', []):
            words = segment.get('words') or []
            if not words:
                excluded['segments_without_words'] += 1
            for word in words:
                # Segment-level labels do not prove each word has an assignment.
                item = interval(word.get('start'), word.get('end'), word.get('speaker'))
                if item is None:
                    excluded['words_without_valid_timing'] += 1
                else:
                    output[track].append(item)
    return output, dict(excluded)


def timeline(left, right):
    events = defaultdict(list)
    for side, values in enumerate((left, right)):
        for start, end, speaker in values:
            events[start].append((side, speaker, 1))
            events[end].append((side, speaker, -1))
    states = [Counter(), Counter()]
    previous = None
    result = []
    for time in sorted(events):
        if previous is not None and time > previous:
            result.append((previous, time, tuple(frozenset(s) for s in states)))
        for side, speaker, delta in events[time]:
            states[side][speaker] += delta
            if states[side][speaker] == 0:
                del states[side][speaker]
        previous = time
    return result


def maximum_mapping(weights):
    """Maximum-duration one-to-one anonymous-label mapping using Hungarian assignment."""
    left = sorted({a for a, _ in weights})
    right = sorted({b for _, b in weights})
    n = max(len(left), len(right))
    if not n:
        return {}
    best = max(weights.values(), default=0)
    cost = [[best - (weights.get((left[i], right[j]), 0) if i < len(left) and j < len(right) else 0)
             for j in range(n)] for i in range(n)]
    u, v, p, way = [0.] * (n + 1), [0.] * (n + 1), [0] * (n + 1), [0] * (n + 1)
    for i in range(1, n + 1):
        p[0] = i
        j0 = 0
        minima, used = [math.inf] * (n + 1), [False] * (n + 1)
        while True:
            used[j0] = True
            i0, delta, j1 = p[j0], math.inf, 0
            for j in range(1, n + 1):
                if not used[j]:
                    current = cost[i0 - 1][j - 1] - u[i0] - v[j]
                    if current < minima[j]:
                        minima[j], way[j] = current, j0
                    if minima[j] < delta:
                        delta, j1 = minima[j], j
            for j in range(n + 1):
                if used[j]:
                    u[p[j]] += delta
                    v[j] -= delta
                else:
                    minima[j] -= delta
            j0 = j1
            if p[j0] == 0:
                break
        while True:
            j1 = way[j0]
            p[j0] = p[j1]
            j0 = j1
            if j0 == 0:
                break
    return {left[p[j] - 1]: right[j - 1] for j in range(1, n + 1)
            if 0 < p[j] <= len(left) and j <= len(right)
            and weights.get((left[p[j] - 1], right[j - 1]), 0) > 0}


def compare_track(left, right):
    cells = timeline(left, right)
    weights = defaultdict(float)
    fields = ['timed_seconds', 'speaker_covered_seconds', 'unresolved_only_seconds',
              'multiple_speaker_seconds', 'assigned_and_unresolved_overlap_seconds']
    totals = [Counter(dict.fromkeys(fields, 0.0)), Counter(dict.fromkeys(fields, 0.0))]
    for start, end, states in cells:
        duration = end - start
        labels = [s - {None} for s in states]
        for i in (0, 1):
            if states[i]:
                totals[i]['timed_seconds'] += duration
            if labels[i]:
                totals[i]['speaker_covered_seconds'] += duration
            if states[i] and not labels[i]:
                totals[i]['unresolved_only_seconds'] += duration
            if len(labels[i]) > 1:
                totals[i]['multiple_speaker_seconds'] += duration
            if None in states[i] and labels[i]:
                totals[i]['assigned_and_unresolved_overlap_seconds'] += duration
        if all(len(s) == 1 and None not in s for s in states):
            weights[(next(iter(states[0])), next(iter(states[1])))] += duration
    mapping = maximum_mapping(weights)
    mutual = sum(weights.values())
    agreed = sum(duration for (a, b), duration in weights.items() if mapping.get(a) == b)
    differences = []
    for start, end, states in cells:
        labels = [s - {None} for s in states]
        reason = None
        if all(len(s) == 1 and None not in s for s in states):
            if mapping.get(next(iter(states[0]))) != next(iter(states[1])):
                reason = 'different_mapped_speaker'
        elif bool(labels[0]) != bool(labels[1]):
            reason = 'different_attribution_coverage'
        elif any(len(s) > 1 for s in labels):
            reason = 'multiple_speaker_output'
        if reason:
            if differences and differences[-1]['end'] == start and differences[-1]['reason'] == reason:
                differences[-1]['end'] = end
            else:
                differences.append({'start': start, 'end': end, 'reason': reason})
    return {'local': dict(totals[0]), 'remote': dict(totals[1]), 'local_to_remote_speaker_mapping': mapping,
            'mutually_single_speaker_seconds': mutual, 'mapped_agreement_seconds': agreed,
            'mapped_agreement_fraction': agreed / mutual if mutual else None,
            'difference_windows': sorted(differences, key=lambda x: x['end'] - x['start'], reverse=True)[:30]}


def write_private_text(destination, text, inputs):
    destination = destination.resolve()
    if destination in {path.resolve() for path in inputs}:
        raise ValueError('Comparison output must not overwrite an input.')
    roots = [Path('/private/tmp'), Path(tempfile.gettempdir()).resolve(),
             Path(__file__).resolve().parent / '.local']
    if not any(destination.is_relative_to(root) for root in roots):
        raise ValueError('Write comparison output to a system temporary directory or this experiment’s .local directory.')
    missing = []
    parent = destination.parent
    while not parent.exists():
        missing.append(parent)
        parent = parent.parent
    for parent in reversed(missing):
        parent.mkdir(mode=0o700)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=destination.parent,
                                         prefix='.comparison-', delete=False) as file:
            temporary = Path(file.name)
            os.chmod(temporary, 0o600)
            file.write(text)
        os.replace(temporary, destination)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def write_private_result(destination, result, inputs):
    write_private_text(destination, json.dumps(result, indent=2, ensure_ascii=False) + '\n', inputs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--local', required=True, type=Path, help='Projected local transcript JSONL; copied artifact only.')
    parser.add_argument('--remote', required=True, type=Path, help='Complete deployed-worker response JSON.')
    parser.add_argument('--state', required=True, type=Path, help='Copied audio manifest from run.py.')
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    state = json.loads(args.state.read_text())
    local, le = normalize_local([json.loads(line) for line in args.local.read_text().splitlines() if line.strip()], state['tracks'])
    remote, re = normalize_remote(json.loads(args.remote.read_text()), state['tracks'])
    result = {'version': 1, 'method': 'Final aligned label agreement; not raw acoustic DER or accuracy.',
              'limitations': ['One-to-one mapping optimized on the same comparison time.',
                              'Agreement excludes unresolved and simultaneous-label intervals; coverage reported separately.',
                              'Different transcription and alignment timestamps affect the result.',
                              'Manual ground truth is not available; model correctness is not measured.',
                              'Local inferred labels are included; agreement does not validate them.'],
              'excluded': {'local': le, 'remote': re}, 'tracks': {}}
    for track in state['tracks']:
        name = track['track']
        result['tracks'][name] = {'source': track['source'], 'audio_sha256': track['sha256'],
                                 **compare_track(local[name], remote[name])}
    write_private_result(args.out, result, [args.local, args.remote, args.state])


if __name__ == '__main__':
    main()
