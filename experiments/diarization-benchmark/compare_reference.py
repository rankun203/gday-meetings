"""Compare anonymous diarization intervals with unverified transcript annotations."""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
import math
from pathlib import Path


def assignment(weights):
    """Maximum-weight one-to-one assignment, with zero-weight dummy speakers."""
    rows = len(weights)
    cols = len(weights[0]) if rows else 0
    if any(len(row) != cols or any(not math.isfinite(value) for value in row)
           for row in weights):
        raise ValueError('assignment weights must be rectangular and finite')
    n = max(rows, cols)
    cost = [[-weights[i][j] if i < rows and j < cols else 0.0
             for j in range(n)] for i in range(n)]
    u, v, p, way = ([0.0] * (n + 1), [0.0] * (n + 1),
                     [0] * (n + 1), [0] * (n + 1))
    for i in range(1, n + 1):
        p[0] = i
        j0 = 0
        minimum, used = [math.inf] * (n + 1), [False] * (n + 1)
        while True:
            used[j0] = True
            i0, delta, j1 = p[j0], math.inf, 0
            for j in range(1, n + 1):
                if not used[j]:
                    cur = cost[i0 - 1][j - 1] - u[i0] - v[j]
                    if cur < minimum[j]:
                        minimum[j], way[j] = cur, j0
                    if minimum[j] < delta:
                        delta, j1 = minimum[j], j
            for j in range(n + 1):
                if used[j]:
                    u[p[j]] += delta
                    v[j] -= delta
                else:
                    minimum[j] -= delta
            j0 = j1
            if p[j0] == 0:
                break
        while j0:
            j1 = way[j0]
            p[j0] = p[j1]
            j0 = j1
    return {p[j] - 1: j - 1 for j in range(1, n + 1)
            if p[j] <= rows and j <= cols}


def compare(reference, hypothesis, duration, collar=0.0, exclude_overlap=False):
    """Integrate half-open intervals; unknown reference gaps are not silence.

    Collars exclude a half-width on each side of every original reference
    segment boundary, including adjacent segments with the same label. Mapping
    is fitted only on scored regions, after collar and overlap exclusions.
    Duplicate intervals for one speaker count once; distinct speakers count
    separately. Gap activity is reported even inside a boundary collar.
    """
    if not math.isfinite(duration) or duration <= 0:
        raise ValueError('duration must be finite and positive')
    if not math.isfinite(collar) or collar < 0:
        raise ValueError('collar must be finite and nonnegative')
    events = defaultdict(list)
    events[0.0], events[duration] = [], []
    for kind, intervals in enumerate((reference, hypothesis)):
        for item in intervals:
            start, end, speaker = item['start'], item['end'], item['speaker']
            if not isinstance(speaker, str) or not speaker:
                raise ValueError('speaker must be a nonempty string')
            if (not all(math.isfinite(x) for x in (start, end))
                    or not 0 <= start < duration
                    or not start < end <= duration + 1e-6):
                raise ValueError('interval outside audio or invalid')
            end = min(end, duration)
            events[start].append((kind, speaker, 1))
            events[end].append((kind, speaker, -1))
            if kind == 0 and collar:
                for boundary in (start, end):
                    events[max(0, boundary - collar)].append((2, 'collar', 1))
                    events[min(duration, boundary + collar)].append((2, 'collar', -1))
    states = [Counter(), Counter(), Counter()]
    pieces, unknown_hypothesis, excluded = [], 0.0, 0.0
    times = sorted(events)
    for pos, start in enumerate(times[:-1]):
        for kind, speaker, change in events[start]:
            states[kind][speaker] += change
        width = times[pos + 1] - start
        refs, hyps = ({k for k, count in s.items() if count > 0} for s in states[:2])
        if not refs:
            unknown_hypothesis += width * len(hyps)
        elif states[2]['collar'] > 0 or (exclude_overlap and len(refs) > 1):
            excluded += width
        else:
            pieces.append((start, times[pos + 1], refs, hyps))
    refs = sorted({r for _, _, rs, _ in pieces for r in rs})
    hyps = sorted({h for _, _, _, hs in pieces for h in hs})
    ri, hi = ({s: i for i, s in enumerate(items)} for items in (refs, hyps))
    weights = [[0.0 for _ in refs] for _ in hyps]
    for start, end, rs, hs in pieces:
        for h in hs:
            for r in rs:
                weights[hi[h]][ri[r]] += end - start
    mapping = {hyps[h]: refs[r] for h, r in assignment(weights).items()}
    missed = extra = confusion = denominator = scored = 0.0
    disagreements = []
    for start, end, rs, hs in pieces:
        width = end - start
        correct = len(rs & {mapping[h] for h in hs if h in mapping})
        miss, false, wrong = max(0, len(rs) - len(hs)), max(0, len(hs) - len(rs)), min(len(rs), len(hs)) - correct
        missed += width * miss
        extra += width * false
        confusion += width * wrong
        denominator += width * len(rs)
        scored += width
        if miss + false + wrong:
            disagreements.append({'start': start, 'end': end, 'speaker_seconds': width * (miss + false + wrong)})
    return dict(reference_status='unverified_annotations_not_ground_truth',
                mask='union_of_reference_speech_intervals', collar_half_width_seconds=collar,
                exclude_reference_overlap=exclude_overlap, scored_wall_seconds=scored,
                reference_speaker_seconds=denominator, excluded_reference_wall_seconds=excluded,
                missed_speaker_seconds=missed, extra_speaker_seconds=extra,
                confused_speaker_seconds=confusion,
                disagreement_fraction=(missed + extra + confusion) / denominator if denominator else None,
                hypothesis_speaker_seconds_in_unknown_gaps=unknown_hypothesis,
                mapping=mapping, review_intervals=sorted(disagreements, key=lambda x: x['speaker_seconds'], reverse=True)[:10])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--segments', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    worktree = Path(__file__).resolve().parents[2]
    if output == worktree or worktree in output.parents:
        parser.error('Private outputs must be outside the worktree')
    for source in (args.reference, args.segments):
        if output == source.resolve() or (output.exists() and output.samefile(source)):
            parser.error('Output must not overwrite the reference or segments input')
    ref = json.loads(args.reference.read_text())
    hyp = []
    for line in args.segments.read_text().splitlines():
        row = json.loads(line)
        if row.get('window_end_seconds', 0) > 0 or row.get('update_id', 0) > 0 or 'update_index' in row:
            raise ValueError('Window replay requires separate per-update scoring; use full-file outputs')
        hyp.append(dict(start=row['start_seconds'], end=row['end_seconds'], speaker=row['speaker']))
    result = {'schema_version': 1, 'reference_sha256': hashlib.sha256(args.reference.read_bytes()).hexdigest(),
              'segments_sha256': hashlib.sha256(args.segments.read_bytes()).hexdigest(),
              'comparisons': [compare(ref['intervals'], hyp, ref['audioDurationSeconds'], collar, overlap)
                              for collar in (0, 0.25) for overlap in (False, True)]}
    # Exclusive creation also prevents overwriting an input through a newly
    # created alias, or replacing an earlier comparison by mistake.
    with output.open('x') as handle:
        handle.write(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
