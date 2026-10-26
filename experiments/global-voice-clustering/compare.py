#!/usr/bin/env python3
"""Reproducible, descriptive voice-grouping replay; no human identity truth is assumed."""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
from collections import defaultdict
from pathlib import Path
import time

import numpy as np


def valid(sample):
    values = sample.get('embedding', [])
    return (sample.get('eligible', True) and bool(values) and len(values) <= 4096
            and all(math.isfinite(x) for x in values) and any(x != 0 for x in values))


def matrix(samples):
    result = np.full((len(samples), len(samples)), -1., dtype=np.float64)
    models = defaultdict(list)
    for i, sample in enumerate(samples):
        if valid(sample):
            models[(sample['model'], len(sample['embedding']))].append(i)
    for indices in models.values():
        values = np.asarray([samples[i]['embedding'] for i in indices], dtype=np.float64)
        values /= np.max(np.abs(values), axis=1, keepdims=True)
        values /= np.linalg.norm(values, axis=1, keepdims=True)
        result[np.ix_(indices, indices)] = np.clip(values @ values.T, -1, 1)
    return result


def complete_link(sim, threshold=.8, margin=.08):
    """Port of VoiceAutomaticGrouping nearest-neighbor chain and margin deferral."""
    n = len(sim)
    distances = sim.copy()
    active = set(range(n))
    members = [[i] for i in range(n)]
    chain = []
    while active:
        if not chain:
            chain = [min(active)]
        current = chain[-1]
        previous = chain[-2] if len(chain) > 1 else None
        nearest = previous
        strongest = distances[current, previous] if previous is not None else -2.
        alternatives = np.asarray(sorted(active - {current}), dtype=int)
        if alternatives.size:
            candidate = int(alternatives[np.argmax(distances[current, alternatives])])
            if distances[current, candidate] > strongest:
                nearest, strongest = candidate, distances[current, candidate]
        if nearest is None or strongest < threshold:
            active.remove(current)
            chain = []
        elif nearest != previous:
            chain.append(nearest)
        else:
            chain = chain[:-2]
            keep, remove = sorted((current, nearest))
            members[keep] += members[remove]
            members[remove] = []
            active.remove(remove)
            others = np.asarray(sorted(active - {keep}), dtype=int)
            distances[keep, others] = np.minimum(distances[keep, others], distances[remove, others])
            distances[others, keep] = distances[keep, others]
    clusters = sorted((v for v in members if v), key=min)
    if len(clusters) <= 1:
        return clusters
    output = []
    for group in clusters:
        if len(group) == 1:
            output.append(group)
            continue
        outside = sorted(set(range(n)) - set(group))
        confident = []
        for i in group:
            weakest = float(np.min(sim[i, [j for j in group if i != j]]))
            competitor = float(np.max(sim[i, outside])) if outside else -1.
            if weakest - competitor >= margin:
                confident.append(i)
            else:
                output.append([i])
        if confident:
            output.append(confident)
    return output


def dbscan(samples, sim, threshold=.8, min_samples=3, density='raw'):
    """Batch DBSCAN, self included. Stable ID order determines ambiguous border ownership.

    Density variants count distinct exact-support keys or meeting/local-label keys in
    each neighborhood. They are explicit experimental alternatives to raw DBSCAN.
    """
    n = len(samples)
    eligible = [i for i, s in enumerate(samples) if valid(s)]
    partitions = defaultdict(list)
    for i in eligible:
        partitions[(samples[i]['model'], len(samples[i]['embedding']))].append(i)
    neighbors = {}
    for indices in partitions.values():
        compatible = np.asarray(indices, dtype=int)
        for i in indices:
            neighbors[i] = compatible[sim[i, compatible] >= threshold - 1e-12].tolist()
    def key(j):
        sample = samples[j]
        if density == 'exact_support':
            return sample.get('density_key', sample['id'])
        if density == 'meeting_label':
            return (sample['meeting_id'], sample.get('local_speaker', sample['id']))
        return sample['id']
    core = {i for i in eligible if len({key(j) for j in neighbors[i]}) >= min_samples}
    visited, assigned, groups = set(), set(), []
    for i in eligible:
        if i in visited:
            continue
        visited.add(i)
        if i not in core:
            continue
        group, queue = [], [i]
        queued = {i}
        while queue:
            j = queue.pop()
            if j not in assigned:
                group.append(j)
                assigned.add(j)
            if j not in visited or j == i:
                visited.add(j)
                if j in core:
                    for k in neighbors[j]:
                        if k not in queued:
                            queue.append(k)
                            queued.add(k)
        groups.append(sorted(group))
    # DBSCAN noise points are separate unresolved observations, never one identity.
    groups.extend([[i] for i in range(n) if i not in assigned])
    return groups, core


def profile_indices(samples, sim, limit=12):
    by_person_model = defaultdict(list)
    seen = set()
    conflicts = defaultdict(set)
    for sample in samples:
        if valid(sample) and sample.get('confirmed') and sample.get('person_id'):
            conflicts[sample.get('density_key', sample['id'])].add(sample['person_id'])
    for i, sample in enumerate(samples):
        if not (valid(sample) and sample.get('confirmed') and sample.get('person_id')
                and sample.get('active_reference', True)):
            continue
        audio = sample.get('density_key', sample['id'])
        if len(conflicts[audio]) > 1:
            continue
        key = (audio, sample['person_id'], sample['model'])
        if key in seen:
            continue
        seen.add(key)
        by_person_model[(sample['person_id'], sample['model'])].append(i)
    selected = []
    for candidates in by_person_model.values():
        if len(candidates) <= limit:
            selected.extend(candidates)  # Selection order cannot change maximum-cosine scoring.
            continue
        # VoiceMatchingWorker constructs SpeakerEvidenceSample with default quality 1.
        quality = {i: min(1., max(0., samples[i].get('duration', 0.) / 3.)) for i in candidates}
        first = max(candidates, key=lambda i: (float(np.mean(sim[i, candidates])) + .1 * quality[i], -i))
        chosen = [first]
        remaining = set(candidates) - {first}
        while remaining and len(chosen) < limit:
            next_index = max(remaining, key=lambda i: (1 - max(sim[i, j] for j in chosen) + .1 * quality[i], -i))
            chosen.append(next_index)
            remaining.remove(next_index)
        selected.extend(chosen)
    return selected


def group_id(samples, indices, prefix):
    return prefix + ':' + hashlib.sha256('\0'.join(sorted(samples[i]['id'] for i in indices)).encode()).hexdigest()[:16]


def assign_groups(samples, groups, prefix, cold=False, core=None):
    output = {}
    for indices in groups:
        anchors = {samples[i]['person_id'] for i in indices if samples[i].get('confirmed')
                   and samples[i].get('person_id') and valid(samples[i])} if not cold else set()
        conflict = len(anchors) > 1
        gid = group_id(samples, indices, prefix)
        for i in indices:
            sample = samples[i]
            explicit = sample.get('person_id') if sample.get('confirmed') and not cold else None
            person = explicit or (next(iter(anchors)) if len(anchors) == 1 else None)
            rejected = person in sample.get('rejected_person_ids', [])
            if rejected and not explicit:
                person = None
            state = ('excluded' if not valid(sample) else 'confirmed' if explicit else
                     'conflict' if conflict else 'rejected' if rejected else
                     'inferred' if person else 'unknown')
            if not valid(sample):
                person = explicit  # Exclusion withdraws recognition evidence, preserving the durable decision.
            output[sample['id']] = {'group': gid, 'person_id': person, 'state': state,
                                    'conflict': conflict, 'core': i in core if core is not None else None,
                                    'noise': bool(valid(sample) and len(indices) == 1 and i not in core) if core is not None else None}
    return output


def recognition(samples, sim, limit=12, threshold=.8, margin=.08):
    refs = profile_indices(samples, sim, limit)
    groups = defaultdict(list)
    for i, sample in enumerate(samples):
        groups[(sample['meeting_id'], sample.get('local_speaker') or sample['id'], sample['model'])].append(i)
    output = assign_groups(samples, list(groups.values()), 'local', cold=True)
    for i, sample in enumerate(samples):
        row = output[sample['id']]
        if not valid(sample):
            if sample.get('confirmed'):
                row['person_id'] = sample.get('person_id')
            continue
        if sample.get('confirmed') and sample.get('person_id'):
            row.update(person_id=sample['person_id'], state='confirmed')
            continue
        scores = defaultdict(lambda: -2.)
        for j in refs:
            if sample['model'] == samples[j]['model'] and len(sample['embedding']) == len(samples[j]['embedding']):
                person = samples[j]['person_id']
                scores[person] = max(scores[person], float(sim[i, j]))
        ranked = sorted(scores.items(), key=lambda x: (-x[1], x[0]))
        if not ranked:
            continue
        person, score = ranked[0]
        gap = score - (ranked[1][1] if len(ranked) > 1 else -1)
        row.update(score=score, margin=gap)
        if person in sample.get('rejected_person_ids', []):
            row['state'] = 'rejected'
        elif gap >= margin and score >= threshold:
            row.update(person_id=person, state='automatic')
        elif len(ranked) >= 2 and gap >= margin and score > 0 and score >= .55:
            row.update(suggested_person_id=person, state='tentative')
    return output, len(refs)


def metrics(assignments):
    groups = defaultdict(list)
    for row in assignments.values():
        if row['state'] != 'excluded':
            groups[row['group']].append(row)
    return {'samples': len(assignments), 'eligible': sum(len(v) for v in groups.values()),
            'groups': len(groups), 'non_singleton_groups': sum(len(v) > 1 for v in groups.values()),
            'grouped_samples': sum(len(v) for v in groups.values() if len(v) > 1),
            'identified_samples': sum(r['person_id'] is not None for r in assignments.values()),
            'inferred_samples': sum(r['state'] in ('inferred', 'automatic') for r in assignments.values()),
            'unknown_samples': sum(r['state'] == 'unknown' for r in assignments.values()),
            'tentative_samples': sum(r['state'] == 'tentative' for r in assignments.values()),
            'conflict_groups': len({r['group'] for r in assignments.values() if r.get('conflict')}),
            'core_samples': sum(r.get('core') is True for r in assignments.values()),
            'noise_samples': sum(r.get('noise') is True for r in assignments.values()),
            'largest_group': max(map(len, groups.values()), default=0)}


def changes(before, after):
    shared = sorted(set(before) & set(after))
    # Count agreeing co-membership through contingency counts, independent of labels.
    old, new, intersections = defaultdict(int), defaultdict(int), defaultdict(int)
    identities = 0
    for key in shared:
        a, b = before[key], after[key]
        old[a['group']] += 1
        new[b['group']] += 1
        intersections[(a['group'], b['group'])] += 1
        identities += a['person_id'] != b['person_id']
    pairs = lambda counts: sum(n * (n - 1) // 2 for n in counts.values())
    return {'shared_samples': len(shared), 'co_membership_changed_pairs': pairs(old) + pairs(new) - 2 * pairs(intersections),
            'co_membership_pairs': len(shared) * (len(shared) - 1) // 2, 'identity_changed': identities}


def run_methods(samples, sim=None, full=True):
    sim = matrix(samples) if sim is None else sim
    output = {}
    def add(name, assignments, **extra):
        by_id = {sample['id']: sample for sample in samples}
        confirmed_support = {sample.get('density_key', sample['id']) for sample in samples
                             if sample.get('confirmed') and sample.get('person_id')}
        inferred_ids = [sid for sid, row in assignments.items() if row['state'] in ('inferred', 'automatic')]
        inferred_support = {by_id[sid].get('density_key', sid) for sid in inferred_ids}
        physical = {'inferred_novel_support': len(inferred_support - confirmed_support),
                    'inferred_novel_physical_samples': len(inferred_support - confirmed_support),
                    'inferred_unique_physical_samples': len(inferred_support),
                    'inferred_duplicate_anchor_samples': sum(by_id[sid].get('density_key', sid) in confirmed_support
                                                             for sid in inferred_ids)}
        output[name] = {'assignments': assignments, 'metrics': metrics(assignments) | extra | physical}
    local, ref_count = recognition(samples, sim)
    add('current_local_library', local, references=ref_count)
    unlimited, count = recognition(samples, sim, limit=len(samples) + 1)
    add('unlimited_reference', unlimited, references=count)
    if full:
        eligible = [i for i, s in enumerate(samples) if valid(s) and not s.get('confirmed')]
        clustered = complete_link(sim[np.ix_(eligible, eligible)])
        groups = [[eligible[j] for j in group] for group in clustered]
        groups.extend([[i] for i in range(len(samples)) if i not in set(eligible)])
        grouped = assign_groups(samples, groups, 'complete_link', cold=True)
        # The grouping surface and recognition remain distinct in the app.
        for sid, row in grouped.items():
            row.update({k: v for k, v in local[sid].items() if k != 'group'})
        add('current_library_groups', grouped)
    groups, core = dbscan(samples, sim)
    add('global_dbscan', assign_groups(samples, groups, 'dbscan', core=core))
    add('global_dbscan_cold', assign_groups(samples, groups, 'dbscan', cold=True, core=core))
    unique_groups, unique_core = dbscan(samples, sim, density='exact_support')
    add('global_dbscan_unique', assign_groups(samples, unique_groups, 'dbscan_unique', core=unique_core))
    return output


def evaluate(fixture):
    samples = sorted(fixture['samples'], key=lambda s: s['id'])
    started = time.perf_counter()
    sim = matrix(samples)
    full = run_methods(samples, sim)
    by_meeting = defaultdict(list)
    for i, sample in enumerate(samples):
        by_meeting[(sample.get('meeting_order', 0), sample['meeting_id'])].append(i)
    vector_bearing_meetings = len(by_meeting)
    for meeting in fixture.get('meetings', []):
        by_meeting.setdefault((meeting.get('meeting_order', 0), meeting['id']), [])
    chronological = [by_meeting[key] for key in sorted(by_meeting)]
    arrival = sorted(range(len(samples)), key=lambda i: (samples[i].get('meeting_order', 0),
                     (samples[i].get('support_spans') or [{'start': 0}])[0]['start'], samples[i]['id']))
    batch_size = max(25, math.ceil(len(arrival) / 8))
    batches = [arrival[i:i + batch_size] for i in range(0, len(arrival), batch_size)]
    scenarios = []
    for name, chunks in [('growing_meetings', chronological), (f'incoming_batches_{batch_size}', batches),
                         ('reverse_meetings', list(reversed(chronological)))]:
        seen, previous, checkpoints = [], {}, []
        for step, chunk in enumerate(chunks, 1):
            seen = sorted(seen + chunk)
            current = run_methods([samples[i] for i in seen], sim[np.ix_(seen, seen)])
            checkpoints.append({'step': step, 'samples': len(seen), 'methods': {
                method: {'metrics': value['metrics'], 'change': changes(previous.get(method, {}).get('assignments', {}), value['assignments'])}
                for method, value in current.items()}})
            previous = current
        scenarios.append({'name': name, 'checkpoints': checkpoints,
                          'final_vs_full': {method: changes(full[method]['assignments'], value['assignments'])
                                            for method, value in previous.items()}})
    # Genuine same-input iteration-order test; do not canonicalize the reversed rows.
    reverse_samples = list(reversed(samples))
    reversed_groups, reversed_core = dbscan(reverse_samples, sim[::-1, ::-1])
    reverse_result = assign_groups(reverse_samples, reversed_groups, 'dbscan', core=reversed_core)
    unique_groups, unique_core = dbscan(reverse_samples, sim[::-1, ::-1], density='exact_support')
    unique_reverse_result = assign_groups(reverse_samples, unique_groups, 'dbscan_unique', core=unique_core)
    scenarios.append({'name': 'reverse_dbscan_iteration', 'checkpoints': [],
                      'final_vs_full': {'global_dbscan': changes(full['global_dbscan']['assignments'], reverse_result),
                                        'global_dbscan_unique': changes(full['global_dbscan_unique']['assignments'], unique_reverse_result)}})
    sensitivity = []
    for threshold in [.70, .75, .80, .85, .90]:
        for minimum in [2, 3, 5]:
            for density in ['raw', 'exact_support', 'meeting_label']:
                groups, core = dbscan(samples, sim, threshold, minimum, density)
                assignments = assign_groups(samples, groups, 'dbscan', core=core)
                sensitivity.append({'similarity': threshold, 'min_samples': minimum, 'density': density,
                                    'metrics': metrics(assignments),
                                    'change_vs_default': changes(full['global_dbscan']['assignments'], assignments)})
    return {'schema_version': 1, 'metadata': {
        'elapsed_seconds': time.perf_counter() - started, 'incoming_batch_size': batch_size,
        'incoming_batch_order': 'Simulated recording-time sample arrival: meeting creation order, first support span start, stable sample ID; actual review creation timestamps are unavailable.', 'input_metadata': fixture.get('metadata', {}),
        'policy': {'similarity': .8, 'min_samples': 3, 'margin': .08, 'reference_cap_per_person_model': 12},
        'limitations': [
            'Descriptive grouping and identity propagation; no accuracy, purity, or recall without independent human truth.',
            ('Saved local speaker labels are held fixed; audio diarization is not rerun. Embeddings are regenerated from saved ranges using the extraction pipeline recorded in input metadata.'
             if fixture.get('metadata', {}).get('extraction') else
             'Saved local speaker labels and stored embeddings are held fixed; audio diarization and embedding extraction are not rerun.'),
            'Snapshot confirmations are retrospective anchors. Replay admits anchors only when their source meeting arrives; actual decision-time history is unavailable.',
            'DBSCAN replays fully recompute all arrived evidence; this evaluates batch recomputation, not a production incremental index.',
            'Current profile selection/scoring and automatic grouping are Python ports. Full persistence, exact-decision projection, multi-model agreement and UI proposal scoping are not replayed.',
            'Each typed representation is a separate row; samples with multiple models are not fused. Models and dimensions are partitioned.',
            'Exact-support deduplication does not eliminate overlapping or adjacent excerpts. Meeting-label density is a conservative sensitivity experiment.',
            'Full-snapshot matching includes reference self-matches; confirmed rows are preserved and excluded from inferred-match counts.'
        ]}, 'coverage': {'samples': len(samples), 'eligible': sum(valid(s) for s in samples),
                         'meetings': len(by_meeting), 'vector_bearing_meetings': vector_bearing_meetings, 'models': len({s['model'] for s in samples}),
                         'unique_physical_samples': len({s.get('density_key', s['id']) for s in samples}),
                         'confirmed': sum(bool(s.get('confirmed') and s.get('person_id')) for s in samples)},
        'methods': full, 'scenarios': scenarios, 'sensitivity': sensitivity,
        'synthetic_lifecycle': synthetic_lifecycle()}


def synthetic_lifecycle():
    def sample(sid, angle, person=None, **kwargs):
        return {'id': sid, 'embedding': [math.cos(angle), math.sin(angle)], 'model': 'synthetic-v1',
                'meeting_id': sid, 'meeting_order': 0, 'local_speaker': sid, 'eligible': True,
                'person_id': person, 'confirmed': person is not None, 'density_key': sid, **kwargs}
    initial = [sample('a', 0., 'person-a'), sample('b', .12), sample('c', .24)]
    def derive(rows):
        ordered = sorted(rows, key=lambda s: s['id'])
        groups, core = dbscan(ordered, matrix(ordered))
        return assign_groups(ordered, groups, 'dbscan', core=core)
    before = derive(initial)
    corrected = copy.deepcopy(initial)
    corrected[0]['person_id'] = 'person-b'
    correction = derive(corrected)
    removed = derive(initial[1:])
    undo = derive(initial)
    conflict = derive(initial + [sample('d', .3, 'person-b')])
    rejected = copy.deepcopy(initial)
    rejected[1]['rejected_person_ids'] = ['person-a']
    rejection = derive(rejected)
    duplicated = [sample(str(i), 0., density_key='one-utterance') for i in range(8)]
    duplication = {}
    for density in ['raw', 'exact_support', 'meeting_label']:
        groups, core = dbscan(duplicated, matrix(duplicated), density=density)
        duplication[density] = metrics(assign_groups(duplicated, groups, 'dbscan', core=core))
    replacement = copy.deepcopy(initial)
    replacement[0]['model'] = 'synthetic-v2'
    return {'correction': changes(before, correction), 'removal': changes(before, removed),
            'undo': changes(before, undo), 'conflict': metrics(conflict),
            'rejection': rejection['b'], 'model_replacement': changes(before, derive(replacement)),
            'density_duplication': duplication,
            'checks': {'correction_propagates': correction['b']['person_id'] == 'person-b',
                       'removal_withdraws_identity': all(r['person_id'] is None for r in removed.values()),
                       'undo_restores': before == undo,
                       'conflict_preserves_anchors': conflict['a']['person_id'] == 'person-a' and conflict['d']['person_id'] == 'person-b',
                       'conflict_blocks_inference': conflict['b']['person_id'] is None,
                       'rejection_blocks_identity': rejection['b']['person_id'] is None}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    fixture = json.loads(args.input.read_text())
    result = evaluate(fixture)
    result['metadata']['input_sha256'] = hashlib.sha256(args.input.read_bytes()).hexdigest()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, allow_nan=False) + '\n')
    print(json.dumps({'output': str(args.output), 'coverage': result['coverage'],
                      'methods': {k: v['metrics'] for k, v in result['methods'].items()},
                      'synthetic_checks': result['synthetic_lifecycle']['checks']}))


if __name__ == '__main__':
    main()
