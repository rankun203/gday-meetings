#!/usr/bin/env python3
"""Build reusable, model-independent listening pairs for a completed comparison."""
import argparse
from collections import defaultdict
import hashlib
import itertools
import json
from pathlib import Path
import random

import numpy as np

from review import build_payload, load_variant
from transcript import union_length


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def pair_id(a, b):
    return hashlib.sha256(json.dumps(sorted((a, b)), separators=(',', ':')).encode()).hexdigest()[:24]


def usable_pair(a, b):
    if a['id'] == b['id'] or a['density_key'] == b['density_key']:
        return False
    if a['audio_revision'] == b['audio_revision']:
        return not any(x['start'] < y['end'] and y['start'] < x['end']
                       for x in a['embedding_spans'] for y in b['embedding_spans'])
    return True


def relation(a, b):
    if not a or not b:
        return 'unresolved'
    if a.get('fit_role') == 'overlap_omitted' or b.get('fit_role') == 'overlap_omitted':
        return 'omitted'
    if a.get('noise') or b.get('noise') or a.get('state') == 'excluded' or b.get('state') == 'excluded':
        return 'unresolved'
    return 'same' if a.get('group') and a['group'] == b.get('group') else 'different'


def current_projection(samples, rows):
    """Project unanimous saved labels only when they cover all detected support."""
    overlaps = defaultdict(list)
    for row in rows:
        for span in row['coverage_intervals']:
            overlaps[span['sample_id']].append((row, span))
    result = {}
    for sample in samples:
        evidence = overlaps[sample['id']]
        duration = union_length([(p['start'], p['end']) for p in sample['support_spans']])
        covered = union_length([(s['start'] - r.get('recording_offset', 0),
                                 s['end'] - r.get('recording_offset', 0)) for r, s in evidence])
        if covered < duration - 1e-7 or not evidence or any(r.get('association_uncertain') or r.get('has_unattributed_words') for r, _ in evidence):
            continue
        people = {r.get('saved_person_id') if r.get('saved_person_coverage') == 'full' else None for r, _ in evidence}
        if len(people - {None}) > 1:
            continue
        labels = {r.get('local_label') for r, _ in evidence}
        scopes = {r.get('recording_key') for r, _ in evidence}
        speakers = {r.get('speaker_id') or r.get('local_label') for r, _ in evidence}
        result[sample['id']] = dict(meeting=sample['meeting_id'],
                                    person=next(iter(people)) if len(people) == 1 else None,
                                    local=next(iter(labels)) if len(labels) == 1 else None,
                                    scope=next(iter(scopes)) if len(scopes) == 1 else None,
                                    speaker=next(iter(speakers)) if len(speakers) == 1 else None)
    return result


def passage_sources(samples, rows):
    """Link complete acoustic support to existing human passage corrections."""
    overlaps = defaultdict(list)
    for row in rows:
        for span in row['coverage_intervals']:
            overlaps[span['sample_id']].append((row, span))
    result = {}
    for sample in samples:
        evidence = overlaps[sample['id']]
        wanted = union_length([(p['start'], p['end']) for p in sample['support_spans']])
        covered = union_length([(s['start'] - r.get('recording_offset', 0),
                                 s['end'] - r.get('recording_offset', 0)) for r, s in evidence])
        if wanted > 0 and covered >= wanted - 1e-7:
            result[sample['id']] = sorted({r['id'] for r, _ in evidence})
    return result


def current_relation(a, b):
    if not a or not b:
        return 'unresolved'
    if a.get('person') and b.get('person'):
        return 'same' if a['person'] == b['person'] else 'different'
    if (a['meeting'] == b['meeting'] and a.get('scope') and a['scope'] == b.get('scope')
            and a.get('speaker') and b.get('speaker')):
        return 'same' if a['speaker'] == b['speaker'] else 'different'
    return 'unresolved'


def configurations(root, results):
    configs, assignments = [], {}
    for entry in results['method_catalog']:
        method = entry['id']
        if method == 'current_local_library':
            continue
        for setting in entry.get('variants', []):
            value = load_variant(root, results, method, setting['id'])
            identifier = hashlib.sha256((method + '/' + setting['id']).encode()).hexdigest()[:16]
            model = entry.get('model_key', method.removeprefix('global_dbscan_'))
            algorithm = entry.get('algorithm', 'dbscan')
            label = setting.get('label') or setting.get('description') or setting['id']
            configs.append(dict(id=identifier, method=method, variant=setting['id'],
                                label=f"{entry['label']} · {label}", model=model, algorithm=algorithm,
                                primary='nonoverlap' not in algorithm,
                                density=setting.get('density', value.get('policy', {}).get('density'))))
            assignments[identifier] = value['assignments']
    configs.insert(0, dict(id='current', method='current_local_library', variant='', label='Current Saved App Result',
                           model='current', algorithm='current', primary=True,
                           density='Saved transcript labels projected onto fully covered speech contexts'))
    return configs, assignments


def candidate_pairs(samples, assignments, models, max_candidates=40000):
    """Cover group disagreements and nearby voices; never use transcript text."""
    by_id = {s['id']: s for s in samples}
    representatives = {}
    for sample in sorted(samples, key=lambda row: row['id']):
        representatives.setdefault(sample['density_key'], sample['id'])
    canonical = {sample['id']: representatives[sample['density_key']] for sample in samples}
    listenable = {s['id'] for s in samples
                  if union_length([(p['start'], p['end']) for p in s['support_spans']]) >= 1.0}
    candidates = {}

    def add(a, b, reason):
        a, b = canonical.get(a, a), canonical.get(b, b)
        if a in listenable and b in listenable and usable_pair(by_id[a], by_id[b]):
            key = tuple(sorted((a, b)))
            candidates.setdefault(key, set()).add(reason)

    # Bounded representatives expose both within- and cross-meeting group claims.
    for configuration, values in assignments.items():
        groups = defaultdict(list)
        for identifier, value in values.items():
            if identifier in by_id and not value.get('noise') and value.get('state') != 'excluded':
                groups[value['group']].append(identifier)
        for group in groups.values():
            ordered = sorted((sid for sid in group if sid in listenable), key=lambda sid: hashlib.sha256(sid.encode()).digest())
            chosen, meetings = [], set()
            for identifier in ordered:
                meeting = by_id[identifier]['meeting_id']
                if meeting not in meetings:
                    chosen.append(identifier)
                    meetings.add(meeting)
                if len(chosen) == 4:
                    break
            chosen += [sid for sid in ordered if sid not in chosen][:max(0, 6-len(chosen))]
            for a, b in itertools.combinations(chosen, 2):
                add(a, b, 'Group membership')
        if len(candidates) > max_candidates * 2:
            candidates = dict(sorted(candidates.items(), key=lambda item: pair_id(*item[0]))[:max_candidates])
    # Nearby pairs include speech that every configuration currently leaves unresolved.
    for model in models:
        with np.load(model['embeddings'], allow_pickle=False) as archive:
            ids = archive['ids'].astype(str).tolist()
            vectors = archive['embeddings'].astype(np.float32)
        if set(ids) != set(by_id) or len(ids) != len(by_id):
            raise ValueError('Pair candidates require the complete shared observation domain.')
        vectors /= np.linalg.norm(vectors, axis=1, keepdims=True)
        for start in range(0, len(ids), 128):
            scores = vectors[start:start+128] @ vectors.T
            count = min(8, len(ids))
            nearest = np.argpartition(-scores, count-1, axis=1)[:, :count]
            for row, neighbors in enumerate(nearest):
                a = ids[start+row]
                for index in sorted(neighbors, key=lambda i: (-float(scores[row, i]), ids[i])):
                    b = ids[index]
                    if a in listenable and b in listenable and usable_pair(by_id[a], by_id[b]):
                        add(a, b, 'Nearby voice evidence')
                        break
    return dict(sorted(candidates.items(), key=lambda item: pair_id(*item[0]))[:max_candidates])


def make_queue(samples, configs, assignments, current, candidates, count=2000, control_fraction=.2, seed=20261025):
    if count < 1 or not 0 < control_fraction < 1:
        raise ValueError('Provide a positive queue size and a control fraction between zero and one.')
    by_id = {s['id']: s for s in samples}
    primary = {c['id'] for c in configs if c['primary']}
    families = defaultdict(list)
    for config in configs:
        if config['id'] in primary:
            families[(config.get('model', config['id']), config.get('algorithm', config['id']))].append(config['id'])
    weights = {identifier: 1/len(members) for members in families.values() for identifier in members}

    def predictions(a, b):
        return {c['id']: (current_relation(current.get(a), current.get(b)) if c['id'] == 'current'
                          else relation(assignments[c['id']].get(a), assignments[c['id']].get(b))) for c in configs}

    ranked = []
    for (a, b), reasons in candidates.items():
        votes = predictions(a, b)
        same, different, unresolved = (sum(weights[key] for key,value in votes.items() if key in primary and value == state)
                                        for state in ('same','different','unresolved'))
        resolved = same + different
        # Disagreement is a review priority, not an estimated probability of error.
        score = (2 * min(same, different) / resolved if resolved else 0)
        score += .35 * min(resolved, unresolved) / max(1, len(families))
        score += .05 * (by_id[a]['meeting_id'] != by_id[b]['meeting_id'])
        ranked.append((score, pair_id(a, b), a, b, reasons, votes))
    ranked.sort(key=lambda row: (-row[0], row[1]))
    rng = random.Random(seed)
    # One physical context per control population entry avoids aliases changing sampling weight.
    physical = {}
    for sample in sorted(samples, key=lambda row: row['id']):
        physical.setdefault(sample['density_key'], sample['id'])
    population = list(physical.values())
    controls = set()
    wanted = min(round(count * control_fraction), len(population)*(len(population)-1)//2)
    if len(population) >= 2 and wanted:
        for _ in range(max(100, wanted * 100)):
            a, b = sorted(rng.sample(population, 2))
            if usable_pair(by_id[a], by_id[b]):
                controls.add((a, b))
            if len(controls) >= wanted:
                break
    selected = []
    for score, identifier, a, b, reasons, votes in ranked:
        if (a, b) in controls:
            continue
        selected.append(dict(id=identifier, sample_ids=[a, b], selection='disagreement',
                             reason=' · '.join(sorted(reasons)), priority_score=round(score, 6), predictions=votes))
        if len(selected) >= count-len(controls):
            break
    control_rows = [dict(id=pair_id(a, b), sample_ids=[a, b], selection='control',
                         reason='Random physical-context control', predictions=predictions(a, b)) for a, b in sorted(controls)]
    # Interleave controls rather than burying them after the disagreement queue.
    output = []
    for index in range(max(len(selected), len(control_rows)*4)):
        if index < len(selected):
            output.append(selected[index])
        if index % 4 == 3 and index//4 < len(control_rows):
            output.append(control_rows[index//4])
    return dict(version=1, configs=configs, pairs=output, metadata=dict(seed=seed,
                candidate_pairs=len(candidates), requested_pairs=count, physical_contexts=len(population),
                controls=len(control_rows), selection='Prioritized disagreements plus uniform physical-context pair controls',
                priority_weighting='Equal total weight per model/algorithm family; equal weight per setting within each family',
                limitations=['Prioritized pairs are selected for disagreement and do not estimate population accuracy.',
                             'Random controls sample physical-context pairs, not people uniformly.',
                             'Current labels require full unanimous transcript coverage; cross-meeting local labels remain unresolved.',
                             'Prioritized clips have at least one second of detected speech; random controls retain short speech.',
                             'Near-neighbor and group representatives are bounded candidate heuristics.']))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--models', type=Path, required=True)
    parser.add_argument('--count', type=int, default=2000)
    args = parser.parse_args()
    manifest_hash, builder_hash = digest(args.models), digest(__file__)
    root = args.root.resolve()
    results_path = root/'results.json'
    initial = digest(results_path)
    source_path = root/'review-input.json'
    source_hash = digest(source_path)
    results = json.loads(results_path.read_text())
    source = json.loads(source_path.read_text())
    if source_hash != results['metadata']['input_sha256']:
        raise ValueError('Review source changed.')
    extension = results['metadata'].get('hdbscan_comparison', {})
    if extension.get('models') != 5 or extension.get('models_manifest_sha256') != digest(args.models):
        raise ValueError('Finish attaching HDBSCAN for the same five models before preparing the review queue.')
    samples = [s for s in source['samples'] if s.get('origin') == 'full-recording-speech-detection']
    configs, assignments = configurations(root, results)
    payload = build_payload(root)
    current = current_projection(samples, payload['transcripts']['rows'])
    model_rows = json.loads(args.models.read_text())
    if len(model_rows) != 5 or len({entry['id'] for entry in model_rows}) != 5:
        raise ValueError('The comparison requires five distinct complete model runs.')
    required = {'dbscan', 'hdbscan', 'hdbscan_nonoverlap', 'dbscan_nonoverlap'}
    for entry in model_rows:
        key = entry['id'].removeprefix('global_dbscan_')
        available = {item.get('algorithm', 'dbscan') for item in results['method_catalog']
                     if item.get('model_key', item['id'].removeprefix('global_dbscan_')) == key}
        if not required <= available:
            raise ValueError('The review is missing an algorithm or matched-density control for a model.')
    model_hashes = {entry['id']: digest(entry['embeddings']) for entry in model_rows}
    catalog = {entry['id']: entry for entry in results['method_catalog']}
    if any(catalog.get(identifier, {}).get('embeddings_sha256') != value for identifier, value in model_hashes.items()):
        raise ValueError('Candidate embeddings differ from the measured comparison.')
    current_candidates = {}
    for identifier, prediction in current.items():
        group = (['person', prediction['person']] if prediction.get('person') else
                 ['local', prediction['meeting'], prediction['scope'], prediction['speaker']]
                 if prediction.get('scope') and prediction.get('speaker') else None)
        if group:
            current_candidates[identifier] = dict(group=json.dumps(group), noise=False)
    candidates = candidate_pairs(samples, {**assignments, '_current_candidates': current_candidates}, model_rows)
    results['pair_review'] = make_queue(samples, configs, assignments, current, candidates, count=args.count)
    results['pair_review']['sample_passages'] = passage_sources(samples, payload['transcripts']['rows'])
    results['pair_review']['metadata'].update(builder_sha256=builder_hash, models_manifest_sha256=manifest_hash,
                                            input_sha256=source_hash, comparison_sha256=initial)
    if (digest(results_path) != initial or digest(source_path) != source_hash
            or digest(args.models) != manifest_hash or digest(__file__) != builder_hash
            or any(digest(entry['embeddings']) != model_hashes[entry['id']] for entry in model_rows)):
        raise ValueError('Review changed while preparing pairs; no result was replaced.')
    temporary = results_path.with_suffix('.json.partial')
    temporary.write_text(json.dumps(results, separators=(',', ':'), allow_nan=False)+'\n')
    temporary.replace(results_path)
    print(json.dumps(dict(pairs=len(results['pair_review']['pairs']), configurations=len(configs))))


if __name__ == '__main__':
    main()
