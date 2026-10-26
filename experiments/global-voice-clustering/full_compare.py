#!/usr/bin/env python3
"""Compare full-speech cold DBSCAN with a preserved saved-library replay.

Run with uv run --no-project --with numpy --with scipy python full_compare.py.
Private inputs and outputs belong under tmp/.
"""
import argparse
from collections import defaultdict
import copy
import hashlib
import json
from pathlib import Path
import time

import numpy as np
from scipy import sparse
from scipy.sparse.csgraph import connected_components

from compare import assign_groups, changes, metrics, valid

PRIMARY = 'global_dbscan_full'
BASELINE = 'current_local_library'
THRESHOLDS = (.65, .70, .75, .80)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def full_metadata(full):
    metadata = copy.deepcopy(full.get('metadata', {}))
    if metadata.get('full_speech'):
        # Count windows, not deduplicated extraction jobs. Several windows can
        # share one physical context and still each receive its embedding.
        speech = metadata['full_speech']
        embedded = sum(valid(sample) for sample in full['samples'])
        speech['embedded_windows'] = embedded
        speech['failed_embedding_windows'] = speech.get('windows', len(full['examples'])) - speech.get('excluded_windows', 0) - embedded
    metadata['saved_fixture_availability'] = metadata.pop('availability', {})
    metadata['availability'] = {
        'meetings': len(full['meetings']), 'speech_windows': len(full['examples']),
        'embedding_rows': len(full['samples']),
        'eligible_rows': sum(valid(sample) for sample in full['samples']),
        'examples_without_embeddings': len(full['examples']) - len(full['samples']),
    }
    return metadata


def physical_key(sample):
    return sample.get('density_key') or json.dumps(
        [sample['meeting_id'], sample.get('audio_path'), sample.get('audio_revision'),
         sample.get('support_spans')], sort_keys=True, separators=(',', ':'))


def representatives(samples):
    """One density observation per identical physical support and typed model."""
    representatives, members, seen = [], [], {}
    for index, sample in enumerate(samples):
        if not valid(sample):
            continue
        key = (sample['model'], len(sample['embedding']), physical_key(sample))
        if key in seen:
            position = seen[key]
            previous = samples[representatives[position]]
            if not np.allclose(previous['embedding'], sample['embedding'], rtol=0, atol=1e-12):
                raise ValueError('Identical typed physical support has conflicting embeddings.')
            members[position].append(index)
        else:
            seen[key] = len(representatives)
            representatives.append(index)
            members.append([index])
    return representatives, members


def neighborhood_graph(samples, block_size=256, max_edges=20_000_000):
    """Retain only cosine edges needed by the predeclared sensitivity grid."""
    n = len(samples)
    partitions = defaultdict(list)
    for i, sample in enumerate(samples):
        partitions[(sample['model'], len(sample['embedding']))].append(i)
    rows, columns, values = [], [], []
    count = 0
    for indices in partitions.values():
        vectors = np.asarray([samples[i]['embedding'] for i in indices], dtype=np.float64)
        vectors /= np.max(np.abs(vectors), axis=1, keepdims=True)
        vectors /= np.linalg.norm(vectors, axis=1, keepdims=True)
        ids = np.asarray(indices)
        for start in range(0, len(ids), block_size):
            similarities = np.clip(vectors[start:start + block_size] @ vectors.T, -1, 1)
            r, c = np.nonzero(similarities >= THRESHOLDS[0] - 1e-12)
            count += len(r)
            if count > max_edges:
                raise ValueError(f'Neighborhood edge limit {max_edges} exceeded; increase --max-neighbor-edges after checking available memory.')
            rows.append(ids[start + r])
            columns.append(ids[c])
            values.append(similarities[r, c])
    if not values:
        return sparse.csr_matrix((n, n), dtype=np.float64)
    return sparse.coo_matrix((np.concatenate(values), (np.concatenate(rows), np.concatenate(columns))),
                             shape=(n, n)).tocsr()


def support_intervals(samples, representative_indices):
    """Use the full embedding context; speech-only spans understate overlap."""
    output = []
    for index in representative_indices:
        sample = samples[index]
        spans = sample.get('embedding_spans') or sample.get('support_spans')
        if not spans:
            raise ValueError('Independent density requires embedding support spans.')
        start = min(float(span['start']) for span in spans)
        end = max(float(span['end']) for span in spans)
        if not np.isfinite(start) or not np.isfinite(end) or not 0 <= start < end:
            raise ValueError('Embedding support spans must have finite increasing bounds.')
        revision = sample.get('audio_revision') or ''
        file_key = ('content', revision) if len(revision) == 64 and all(c in '0123456789abcdef' for c in revision.lower()) else (
            sample['meeting_id'], sample.get('audio_path'), revision)
        output.append((file_key, start, end))
    return output


def independent_core(local, intervals, minimum):
    """A core needs min_samples pairwise nonoverlapping embedding contexts.

    Earliest-finish interval scheduling maximizes the count separately per file.
    Multi-span contexts use their envelope, a conservative generalization.
    """
    output = np.zeros(local.shape[0], dtype=bool)
    finishes = np.asarray([value[2] for value in intervals])
    for row in np.flatnonzero(np.diff(local.indptr) >= minimum):
        neighbors = local.indices[local.indptr[row]:local.indptr[row + 1]]
        ordered = neighbors[np.argsort(finishes[neighbors], kind='stable')]
        last_end, count = {}, 0
        for index in ordered:
            file_key, start, end = intervals[int(index)]
            if start >= last_end.get(file_key, -np.inf) - 1e-9:
                last_end[file_key] = end
                count += 1
                if count >= minimum:
                    output[row] = True
                    break
    return output


def cluster(samples, representative_indices, members, graph, threshold=.8, minimum=3, active=None, independent=True, admitted=None):
    """DBSCAN core components with stable first-component border ownership."""
    full_domain = active is None
    active = np.arange(len(representative_indices)) if full_domain else np.asarray(active, dtype=int)
    local = graph[active][:, active].copy()
    local.data = (local.data >= threshold - 1e-12).astype(np.int8)
    local.eliminate_zeros()
    intervals = support_intervals(samples, representative_indices) if independent else []
    core_mask = (independent_core(local, [intervals[int(i)] for i in active], minimum)
                 if independent else np.diff(local.indptr) >= minimum)
    core_indices = np.flatnonzero(core_mask)
    labels = np.full(len(active), -1, dtype=int)
    if len(core_indices):
        _, core_labels = connected_components(local[core_indices][:, core_indices], directed=False)
        # Canonical component order follows the first stable-ID core observation.
        canonical = {}
        for i, label in zip(core_indices, core_labels):
            canonical.setdefault(int(label), len(canonical))
            labels[i] = canonical[int(label)]
        for i in np.flatnonzero(~core_mask):
            adjacent = local.indices[local.indptr[i]:local.indptr[i + 1]]
            adjacent_labels = labels[adjacent[core_mask[adjacent]]]
            if len(adjacent_labels):
                labels[i] = int(adjacent_labels.min())
    groups = defaultdict(list)
    core_original = set()
    included = set()
    for local_index, global_rep in enumerate(active):
        original_members = [i for i in members[int(global_rep)] if admitted is None or i in admitted]
        if not original_members:
            continue
        included.update(original_members)
        label = int(labels[local_index])
        key = ('cluster', label) if label >= 0 else ('noise', int(global_rep))
        groups[key].extend(original_members)
        if core_mask[local_index]:
            core_original.update(original_members)
    # Invalid windows remain explicit excluded observations, including in checkpoints.
    active_meetings = {samples[representative_indices[int(i)]]['meeting_id'] for i in active}
    for i, sample in enumerate(samples):
        if not valid(sample) and (admitted is None or i in admitted) and (full_domain or sample['meeting_id'] in active_meetings):
            groups[('excluded', i)] = [i]
            included.add(i)
    selected = [samples[i] for i in sorted(included)]
    # assign_groups expects indices into its exact sample array.
    lookup = {original: i for i, original in enumerate(sorted(included))}
    result = assign_groups(selected, [[lookup[i] for i in group] for group in groups.values()],
                           'full_dbscan', cold=True, core={lookup[i] for i in core_original})
    # An exact-support duplicate remains one unresolved physical observation when noise.
    for indices in groups.values():
        is_noise = all(i not in core_original for i in indices) and labels.size > 0
        if is_noise and all(valid(samples[i]) for i in indices):
            # Border groups include a core; only standalone noise groups reach here.
            if len({physical_key(samples[i]) for i in indices}) == 1:
                for i in indices:
                    result[samples[i]['id']]['noise'] = True
    return result


def full_metrics(assignments):
    """Physical aliases of one noise observation do not become a cluster."""
    result = metrics(assignments)
    clustered = defaultdict(list)
    for row in assignments.values():
        if row['state'] != 'excluded' and not row.get('noise'):
            clustered[row['group']].append(row)
    result.update(non_singleton_groups=sum(len(group) > 1 for group in clustered.values()),
                  grouped_samples=sum(len(group) for group in clustered.values() if len(group) > 1),
                  largest_group=max(map(len, clustered.values()), default=0))
    return result


def evaluate(full, baseline, baseline_results, block_size=256, max_edges=20_000_000):
    started = time.perf_counter()
    samples = sorted(full['samples'], key=lambda row: row['id'])
    ids = [sample['id'] for sample in samples]
    if len(set(ids)) != len(ids):
        raise ValueError('Full-speech sample IDs must be unique.')
    rep_indices, members = representatives(samples)
    graph = neighborhood_graph([samples[i] for i in rep_indices], block_size, max_edges)
    primary = cluster(samples, rep_indices, members, graph)
    # Include invalid-only meetings in the primary domain.
    missing = [sample for sample in samples if sample['id'] not in primary]
    if missing:
        primary.update(assign_groups(missing, [[i] for i in range(len(missing))], 'full_dbscan', cold=True, core=set()))
    local = copy.deepcopy(baseline_results['methods'][BASELINE])
    output = {PRIMARY: {'assignments': primary, 'metrics': full_metrics(primary)}, BASELINE: local}
    sensitivity = []
    for threshold in THRESHOLDS:
        for minimum in (3, 5):
            assignments = cluster(samples, rep_indices, members, graph, threshold, minimum)
            sensitivity.append({'similarity': threshold, 'min_samples': minimum, 'density': 'nonoverlapping_embedding_support',
                                'metrics': full_metrics(assignments), 'change_vs_default': changes(primary, assignments)})
    meetings = sorted(full['meetings'], key=lambda row: (row.get('meeting_order', 0), row['id']))
    checkpoints, previous = [], {}
    for count in sorted({min(step, len(meetings)) for step in (5, 10, 15, 20)}):
        if not count:
            continue
        admitted = {meeting['id'] for meeting in meetings[:count]}
        active = [i for i, original in enumerate(rep_indices) if samples[original]['meeting_id'] in admitted]
        current = cluster(samples, rep_indices, members, graph, active=active)
        invalid = [s for s in samples if s['meeting_id'] in admitted and not valid(s) and s['id'] not in current]
        current.update(assign_groups(invalid, [[i] for i in range(len(invalid))], 'full_dbscan', cold=True, core=set()))
        baseline_ids = {s['id'] for s in baseline['samples'] if s['meeting_id'] in admitted}
        local_current = {sid: row for sid, row in local['assignments'].items() if sid in baseline_ids}
        current_methods = {PRIMARY: current, BASELINE: local_current}
        checkpoints.append({'step': count, 'samples': len(current), 'methods': {
            method: {'metrics': (full_metrics(assignments) if method == PRIMARY else metrics(assignments)), 'change': changes(previous.get(method, {}), assignments)}
            for method, assignments in current_methods.items()}})
        previous = current_methods
    scenarios = [{'name': 'growing_meetings', 'checkpoints': checkpoints,
                  'final_vs_full': {method: changes(output[method]['assignments'], assignments)
                                    for method, assignments in previous.items()}}]
    arrival = sorted(range(len(samples)), key=lambda i: (samples[i].get('meeting_order', 0),
        min((span['start'] for span in samples[i].get('support_spans', [])), default=0), samples[i]['id']))
    batch_size = max(1, (len(arrival) + 7) // 8)
    seen, previous_samples, sample_checkpoints = set(), {}, []
    for step, start in enumerate(range(0, len(arrival), batch_size), 1):
        seen.update(arrival[start:start + batch_size])
        active = [i for i, originals in enumerate(members) if any(original in seen for original in originals)]
        current = cluster(samples, rep_indices, members, graph, active=active, admitted=seen)
        invalid = [samples[i] for i in seen if not valid(samples[i]) and samples[i]['id'] not in current]
        current.update(assign_groups(invalid, [[i] for i in range(len(invalid))], 'full_dbscan', cold=True, core=set()))
        current_methods = {PRIMARY: current, BASELINE: local['assignments']}
        sample_checkpoints.append({'step': step, 'samples': len(current), 'methods': {
            method: {'metrics': (full_metrics(assignments) if method == PRIMARY else metrics(assignments)), 'change': changes(previous_samples.get(method, {}), assignments)}
            for method, assignments in current_methods.items()}})
        previous_samples = current_methods
    scenarios.append({'name': 'growing_samples', 'checkpoints': sample_checkpoints,
        'final_vs_full': {method: changes(output[method]['assignments'], assignments)
                          for method, assignments in previous_samples.items()}})
    return {'schema_version': 1, 'metadata': {
        'elapsed_seconds': time.perf_counter() - started,
        'incoming_batch_size': batch_size,
        'incoming_batch_order': 'Simulated arrival by meeting order, first speech support start, stable sample ID; up to eight batches. Actual extraction completion order is unavailable.',
        'policy': {'similarity': .8, 'min_samples': 3, 'density': 'nonoverlapping_embedding_support',
                   'automatic_person_naming': False, 'selection': 'Predeclared primary; sensitivity is descriptive and does not select a winner.'},
        'input_metadata': full_metadata(full),
        'neighbor_edges': graph.nnz, 'unique_typed_physical_observations': len(rep_indices),
        'graph_configuration': {'block_size': block_size, 'max_neighbor_edges': max_edges, 'minimum_retained_similarity': THRESHOLDS[0]},
        'limitations': [
            'Cold DBSCAN has no person names; saved confirmations do not inflate density or name clusters.',
            'Current local library assignments are preserved from the baseline numerical replay; transcript comparison uses saved local diarization and person labels.',
            'The methods have different observation domains. Full-speech DBSCAN covers fresh voice windows; the baseline covers saved examples.',
            'Exact physical-support duplicates count once. Core density counts maximum nonoverlapping embedding contexts per physical recording; all windows remain available as core, border, or noise observations.',
            'Nonoverlap density is a declared DBSCAN variant. Multi-span contexts use their bounding interval conservatively; independent-support count does not prove independent speakers.',
            'Meeting and sample checkpoints recompute full-speech clustering on arrived evidence. Meeting checkpoints filter the saved baseline; sample checkpoints retain the full frozen baseline. Neither baseline view replays historical recognition.',
            'Grouping and sensitivity are descriptive. Independent human labels are required to measure identity accuracy.']},
        'coverage': {'samples': len(samples), 'eligible': sum(valid(s) for s in samples),
            'meetings': len(meetings), 'vector_bearing_meetings': len({s['meeting_id'] for s in samples if valid(s)}),
            'models': len({s['model'] for s in samples}), 'unique_physical_samples': len({physical_key(s) for s in samples}),
            'confirmed': 0, 'baseline_samples': len(local['assignments'])},
        'methods': output, 'scenarios': scenarios, 'sensitivity': sensitivity}


def attach_resources(result, paths):
    """Retain attempts individually; failed and interrupted work has a real cost."""
    stages, provenance, counts, limitations = [], [], defaultdict(int), []
    for path in paths:
        receipt = json.loads(path.read_bytes())
        if not isinstance(receipt, dict) or 'stage' not in receipt or 'status' not in receipt:
            raise ValueError(f'Resource receipt lacks stage or status: {path}')
        stages.append(receipt)
        provenance.append({'path': str(path), 'sha256': digest(path)})
        counts[receipt['status']] += 1
        limitations.extend(receipt.get('limitations', []))
    limitations.extend([
        'Only the supplied attempt receipts are included. Earlier baseline extraction, unmeasured work, and unrelated system activity are outside this collection.',
        'Failed, interrupted, and running attempts are retained separately; completion status determines whether a receipt describes a completed stage.',
        'Per-stage wall times and CPU times may overlap when stages run concurrently. Peak memory values must not be summed across stages.',
        'Process RSS and sampled process-tree RSS use different definitions. Accelerator memory, GPU and Neural Engine utilization, energy, and total system impact are unavailable.'])
    result['resources'] = {'stages': stages, 'receipts': provenance, 'attempt_status_counts': dict(counts),
                           'limitations': list(dict.fromkeys(limitations))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--full', required=True, type=Path)
    parser.add_argument('--baseline', required=True, type=Path)
    parser.add_argument('--baseline-results', required=True, type=Path)
    parser.add_argument('--output-root', required=True, type=Path)
    parser.add_argument('--resource-receipt', action='append', default=[], type=Path,
                        help='Attach one resource attempt receipt; repeat for each measured attempt.')
    parser.add_argument('--resources-only', action='store_true',
                        help='Validate existing results and attach receipts without recomputing clustering.')
    parser.add_argument('--block-size', type=int, default=256)
    parser.add_argument('--max-neighbor-edges', type=int, default=20_000_000)
    args = parser.parse_args()
    if args.block_size < 1 or args.max_neighbor_edges < 1:
        parser.error('Block size and neighbor edge limit must be positive.')
    if args.resources_only:
        result_path = args.output_root / 'results.json'
        result = json.loads(result_path.read_bytes())
        checks = {'input_sha256': args.output_root / 'review-input.json',
                  'full_speech_input_sha256': args.full, 'baseline_input_sha256': args.baseline,
                  'baseline_results_sha256': args.baseline_results}
        for field, path in checks.items():
            if result.get('metadata', {}).get(field) != digest(path):
                raise ValueError(f'Existing results do not match {field}.')
        if set(result.get('methods', {})) != {PRIMARY, BASELINE}:
            raise ValueError('Existing results must contain the two expected methods.')
        attach_resources(result, args.resource_receipt)
        result['full_speech'] = result.get('metadata', {}).get('full_speech', {})
        temporary = result_path.with_suffix('.json.partial')
        temporary.write_text(json.dumps(result, indent=2) + '\n')
        temporary.replace(result_path)
        print(json.dumps({'resource_attempts': len(args.resource_receipt), 'clustering_recomputed': False}))
        return
    full = json.loads(args.full.read_bytes())
    baseline = json.loads(args.baseline.read_bytes())
    old_results = json.loads(args.baseline_results.read_bytes())
    if old_results.get('metadata', {}).get('input_sha256') != digest(args.baseline):
        raise ValueError('Baseline results do not match the baseline input.')
    for field in ('samples', 'examples'):
        left = {row['id'] for row in full[field]}
        right = {row['id'] for row in baseline[field]}
        if left & right:
            raise ValueError(f'Full-speech and baseline {field} IDs overlap.')
    if {m['id'] for m in full['meetings']} != {m['id'] for m in baseline['meetings']}:
        raise ValueError('Full-speech and baseline meeting selections differ.')
    combined = copy.deepcopy(full)
    combined['metadata'] = full_metadata(full)
    combined['samples'] += baseline['samples']
    combined['examples'] += baseline['examples']
    combined['people'] = baseline.get('people', [])
    combined['decisions'] = baseline.get('decisions', [])
    combined['metadata']['comparison_domains'] = {PRIMARY: 'fresh full-speech windows', BASELINE: 'saved baseline examples'}
    args.output_root.mkdir(parents=True, exist_ok=True)
    review_path = args.output_root / 'review-input.json'
    review_bytes = (json.dumps(combined, indent=2) + '\n').encode()
    result = evaluate(full, baseline, old_results, args.block_size, args.max_neighbor_edges)
    manifest_path = args.full.parent / 'full-speech-manifest.json'
    result['metadata']['full_speech'] = full_metadata(full).get('full_speech', {})
    result['full_speech'] = copy.deepcopy(result['metadata']['full_speech'])
    attach_resources(result, args.resource_receipt)
    if manifest_path.exists():
        result['metadata']['full_speech_manifest_sha256'] = digest(manifest_path)
        result['metadata']['full_speech_manifest_summary'] = json.loads(manifest_path.read_bytes()).get('summary', {})
    result['metadata'].update(input_sha256=hashlib.sha256(review_bytes).hexdigest(),
        full_speech_input_sha256=digest(args.full), baseline_input_sha256=digest(args.baseline),
        baseline_results_sha256=digest(args.baseline_results))
    raw_path = args.output_root / 'full-speech-enriched.json'
    if raw_path.exists() and digest(raw_path) != digest(args.full):
        raise ValueError('Preserved full-speech input differs; use a new output root.')
    if not raw_path.exists():
        raw_path.write_bytes(args.full.read_bytes())
    review_path.write_bytes(review_bytes)
    (args.output_root / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'methods': list(result['methods']), 'coverage': result['coverage'],
                      'neighbor_edges': result['metadata']['neighbor_edges']}))


if __name__ == '__main__':
    main()
