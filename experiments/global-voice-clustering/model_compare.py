#!/usr/bin/env python3
"""Compare embedding models on identical full-speech observations and settings."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import re
import time

import numpy as np
from scipy import sparse

from compare import changes, valid
from full_compare import cluster, representatives, full_metrics, full_metadata
from model_extract import frames

THRESHOLDS = (.35, .45, .55, .65, .75, .80, .85, .90)


def digest(path):
    with Path(path).open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.json.partial')
    temporary.write_text(json.dumps(value, allow_nan=False, separators=(',', ':')) + '\n')
    temporary.replace(path)


def validate_run(source, entry, input_sha256=None):
    """Bind a complete typed extraction to the exact shared observation plan."""
    samples = source['samples']
    try:
        complete_embeddings = all(valid(sample) for sample in samples)
    except (TypeError, ValueError):
        complete_embeddings = False
    if not complete_embeddings:
        raise ValueError('Comparison requires complete enriched full-speech input with finite nonzero original embeddings.')
    prepared_path, provenance_path = Path(entry['prepared']), Path(entry['provenance'])
    prepared = json.loads(prepared_path.read_text())
    provenance = json.loads(provenance_path.read_text())
    summary = json.loads(Path(entry['summary']).read_text())
    prepared_hash = digest(prepared_path)
    if provenance.get('prepared_sha256') != prepared_hash:
        raise ValueError('Extraction provenance does not match the prepared audio plan.')
    original = Path(prepared['provenance']['input_path'])
    original_hash = digest(original)
    if (original_hash != prepared['provenance']['input_sha256']
            or (input_sha256 is not None and original_hash != input_sha256)
            or json.loads(original.read_text()) != source):
        raise ValueError('Prepared audio belongs to a different full-speech input.')
    manifest_hash = prepared['provenance'].get('manifest_sha256')
    if manifest_hash and digest(original.parent / 'full-speech-manifest.json') != manifest_hash:
        raise ValueError('Original full-speech manifest differs from the prepared audio plan.')
    expected = {sample['id']: sample for sample in samples}
    aliases = {alias['id']: alias for alias in prepared['aliases']}
    jobs = {job['key']: job for job in prepared['jobs']}
    if (not samples or len(expected) != len(samples)
            or len(source['examples']) != len(samples)
            or {example['id'] for example in source['examples']} != set(expected)
            or len(aliases) != len(prepared['aliases']) or set(expected) != set(aliases)
            or len(jobs) != len(prepared['jobs'])
            or {sample['density_key'] for sample in samples} != set(jobs)):
        raise ValueError('Prepared observation coverage is incomplete or duplicated.')
    for identifier, sample in expected.items():
        alias, job = aliases[identifier], jobs[sample['density_key']]
        source_path = str((original.parent / sample['audio_path']).resolve())
        track = prepared['tracks'].get(source_path)
        if (not sample.get('eligible') or track is None or alias['key'] != sample['density_key']
                or alias['embedding_spans'] != sample['embedding_spans']
                or alias['support_spans'] != sample['support_spans']
                or job['source'] != source_path or sample['audio_revision'] != track['source_sha256']):
            raise ValueError('Prepared audio or window support differs from the comparison input.')
        bounds = frames(sample['embedding_spans'], track['decoded_samples'])
        if job['bounds'] != bounds or job['sample_count'] != sum(end-start for start,end in bounds):
            raise ValueError('Prepared sample bounds differ from the comparison input.')
    if (summary.get('complete') is not True or summary.get('benchmark') is not False
            or summary.get('expected_rows') != len(samples)
            or summary.get('unique_jobs') != len(jobs)
            or summary.get('expected_unique_jobs') != len(jobs)):
        raise ValueError('Model extraction must be complete with identical observation coverage.')
    metadata = summary.get('model_metadata', {})
    if metadata != provenance.get('model_metadata') or not metadata.get('model_id'):
        raise ValueError('Model identity differs between summary and extraction provenance.')
    if entry.get('expected_model_id') != metadata['model_id']:
        raise ValueError('Descriptor model identity does not match the requested model.')
    with np.load(entry['embeddings'], allow_pickle=False) as data:
        if 'model_id' not in data or data['model_id'].shape != () or str(data['model_id'].item()) != metadata['model_id']:
            raise ValueError('NPZ model identity does not match extraction provenance.')
        dimension = metadata.get('embedding_dimension', metadata.get('dimension'))
        if dimension is not None and (data['embeddings'].ndim != 2 or data['embeddings'].shape[1] != dimension):
            raise ValueError('NPZ embedding dimension differs from model metadata.')
    return summary, {'prepared_sha256': prepared_hash, 'extraction_provenance_sha256': digest(provenance_path),
                     'summary_sha256': digest(entry['summary']), 'source_input_sha256': original_hash}


def load_samples(source, path, model_id):
    with np.load(path, allow_pickle=False) as data:
        ids = data['ids'].astype(str).tolist()
        vectors = np.asarray(data['embeddings'], dtype=np.float64)
    expected = {row['id'] for row in source['samples']}
    if not expected or len(expected) != len(source['samples']) or len(set(ids)) != len(ids) or set(ids) != expected:
        raise ValueError('Every model must represent exactly the same speech observations.')
    if vectors.ndim != 2 or vectors.shape[0] != len(ids) or vectors.shape[1] < 1:
        raise ValueError('Embedding dimensions do not match observation IDs.')
    if not np.isfinite(vectors).all() or np.any(np.max(np.abs(vectors), axis=1) == 0):
        raise ValueError('Embeddings must be finite and nonzero.')
    vectors /= np.max(np.abs(vectors), axis=1, keepdims=True)
    vectors /= np.linalg.norm(vectors, axis=1, keepdims=True)
    lookup = dict(zip(ids, vectors.tolist()))
    return sorted([{**row, 'model': model_id, 'embedding': lookup[row['id']]} for row in source['samples']], key=lambda row: row['id'])


def graph_at(samples, threshold, max_edges, block_size=256):
    vectors = np.asarray([sample['embedding'] for sample in samples], dtype=np.float64)
    rows, cols, values, count = [], [], [], 0
    for start in range(0, len(samples), block_size):
        similarity = np.clip(vectors[start:start + block_size] @ vectors.T, -1, 1)
        r, c = np.nonzero(similarity >= threshold - 1e-12)
        count += len(r)
        if count > max_edges:
            raise ValueError(f'Neighborhood exceeds the {max_edges:,}-edge resource limit at similarity {threshold:.2f}.')
        rows.append(r + start)
        cols.append(c)
        values.append(similarity[r, c])
    return sparse.coo_matrix((np.concatenate(values), (np.concatenate(rows), np.concatenate(cols))),
                             shape=(len(samples), len(samples))).tocsr()


def arrivals(source, samples, indices, members, graph, threshold=.8, minimum=3):
    meetings = sorted(source['meetings'], key=lambda row: (row['meeting_order'], row['id']))
    sample_order = sorted(range(len(samples)), key=lambda i: (samples[i]['meeting_order'],
        samples[i]['support_spans'][0]['start'], samples[i]['id']))
    batch = max(1, (len(samples) + 7) // 8)
    plans = {'growing_meetings': [(n, {i for i,s in enumerate(samples) if s['meeting_id'] in {m['id'] for m in meetings[:n]}})
                                for n in sorted({min(n, len(meetings)) for n in (5,10,15,20)})],
             'growing_samples': [(n + 1, set(sample_order[:stop])) for n,stop in enumerate(range(batch, len(samples) + batch, batch))]}
    output = []
    for name, plan in plans.items():
        previous, checkpoints = {}, []
        for step, admitted in plan:
            active = [j for j, aliases in enumerate(members) if any(i in admitted for i in aliases)]
            current = cluster(samples, indices, members, graph, threshold, minimum, active=active, admitted=admitted)
            checkpoints.append({'step': step, 'samples': len(current), 'metrics': full_metrics(current), 'change': changes(previous, current)})
            previous = current
        output.append({'name': name, 'checkpoints': checkpoints})
    return output


def evaluate(source, entry, destination, max_edges, input_sha256=None):
    start = time.perf_counter()
    method = entry['id']
    if not re.fullmatch(r'global_dbscan_[a-z0-9_]+', method):
        raise ValueError('Invalid model method ID.')
    inputs = {name: digest(entry[name]) for name in ('embeddings','summary','prepared','provenance')}
    summary, provenance = validate_run(source, entry, input_sha256)
    samples = load_samples(source, entry['embeddings'], method)
    indices, members = representatives(samples)
    unique = [samples[i] for i in indices]
    skipped = []
    graph = None
    for threshold in THRESHOLDS:
        try:
            graph = graph_at(unique, threshold, max_edges)
            minimum_threshold = threshold
            break
        except ValueError as error:
            skipped.append({'similarity': threshold, 'status': 'resource_limit', 'reason': str(error)})
    if graph is None or minimum_threshold > .8:
        raise ValueError('The default setting exceeds the graph resource limit; no incomplete model result was published.')
    variants, default = [], None
    for threshold in THRESHOLDS:
        if threshold < minimum_threshold:
            continue
        for minimum in (3, 5):
            variant = f's{round(threshold * 100):03d}_m{minimum}'
            assignments = cluster(samples, indices, members, graph, threshold, minimum)
            metrics = full_metrics(assignments)
            policy = {'similarity': threshold, 'min_samples': minimum, 'density': 'nonoverlapping_embedding_support'}
            relative = Path('variants') / method / f'{variant}.json'
            value = {'method': method, 'variant': variant, 'assignments': assignments, 'metrics': metrics, 'policy': policy}
            write_json(destination / relative, value)
            variants.append({'id': variant, **policy, 'metrics': metrics, 'path': str(relative), 'sha256': digest(destination / relative)})
            if variant == 's080_m3':
                default = value
    catalog = {**{k:entry[k] for k in ('id','label','short_label') if k in entry}, 'default_variant': 's080_m3',
               'variants': variants, 'skipped_settings': skipped,
               'embedding_metadata': summary, 'provenance': provenance,
               'embeddings_sha256': inputs['embeddings'], 'embedding_dimensions': len(samples[0]['embedding']),
               'neighbor_edges': graph.nnz, 'elapsed_seconds': time.perf_counter() - start}
    scenarios = arrivals(source, samples, indices, members, graph)
    if any(digest(entry[name]) != value for name,value in inputs.items()):
        raise ValueError('Model run inputs changed during comparison.')
    return default, catalog, scenarios


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--baseline-input', type=Path, required=True)
    parser.add_argument('--baseline-results', type=Path, required=True)
    parser.add_argument('--models', type=Path, required=True, help='JSON array of complete model run descriptors.')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--max-neighbor-edges', type=int, default=20_000_000)
    args = parser.parse_args()
    inputs = {path: digest(path) for path in (args.input,args.baseline_input,args.baseline_results,args.models)}
    source = json.loads(args.input.read_text())
    baseline = json.loads(args.baseline_input.read_text())
    old = json.loads(args.baseline_results.read_text())
    entries = json.loads(args.models.read_text())
    if old['metadata']['input_sha256'] != digest(args.baseline_input):
        raise ValueError('Saved baseline input does not match its results.')
    if len({entry['id'] for entry in entries}) != len(entries):
        raise ValueError('Model IDs must be unique.')
    if not entries:
        raise ValueError('Provide at least one complete model run.')
    source_hash = digest(args.input)
    run_provenance = [validate_run(source, entry, source_hash)[1] for entry in entries]
    if len({receipt['prepared_sha256'] for receipt in run_provenance}) != 1:
        raise ValueError('Every model must use the same canonical audio preparation plan.')
    combined = copy.deepcopy(source)
    combined['metadata'] = full_metadata(source)
    combined['metadata']['comparison_domains'] = 'All DBSCAN models use identical canonical audio and speech windows; current sample metrics use saved examples.'
    combined['samples'] += baseline['samples']
    combined['examples'] += baseline['examples']
    combined['people'] = baseline.get('people', [])
    combined['decisions'] = baseline.get('decisions', [])
    methods = {'current_local_library': copy.deepcopy(old['methods']['current_local_library'])}
    catalog = [{'id':'current_local_library','label':'Current · Saved App Result','short_label':'Current'}]
    scenarios = {}
    for entry in entries:
        default, item, model_arrivals = evaluate(source, entry, args.output, args.max_neighbor_edges, source_hash)
        methods[entry['id']] = default
        catalog.append(item)
        for scenario in model_arrivals:
            target = scenarios.setdefault(scenario['name'], {'name':scenario['name'], 'checkpoints':[]})
            if not target['checkpoints']:
                target['checkpoints'] = [{'step':c['step'],'samples':c['samples'],'methods':{}} for c in scenario['checkpoints']]
            for row, current in zip(target['checkpoints'], scenario['checkpoints']):
                row['methods'][entry['id']] = {k:current[k] for k in ('metrics','change')}
        print(json.dumps({'model':entry['id'],'metrics':default['metrics'],'variants':len(item['variants'])}),flush=True)
    for scenario in scenarios.values():
        previous = {}
        for point in scenario['checkpoints']:
            if scenario['name'] == 'growing_meetings':
                admitted = {m['id'] for m in sorted(source['meetings'],key=lambda m:m['meeting_order'])[:point['step']]}
                selected = {s['id'] for s in baseline['samples'] if s['meeting_id'] in admitted}
                current = {k:v for k,v in methods['current_local_library']['assignments'].items() if k in selected}
            else:
                current = methods['current_local_library']['assignments']
            point['methods']['current_local_library'] = {'metrics':full_metrics(current),'change':changes(previous,current)}
            previous = current
    if any(digest(path) != value for path,value in inputs.items()):
        raise ValueError('Comparison inputs changed during evaluation.')
    args.output.mkdir(parents=True,exist_ok=True)
    write_json(args.output/'review-input.json',combined)
    result = {'schema_version':2,'metadata':{'input_sha256':digest(args.output/'review-input.json'),
        'full_speech_input_sha256':digest(args.input),'baseline_input_sha256':digest(args.baseline_input),
        'baseline_results_sha256':digest(args.baseline_results),'models_manifest_sha256':digest(args.models),
        'evaluator_sha256':digest(Path(__file__)),'policy':{'similarity':.8,'min_samples':3,'density':'nonoverlapping_embedding_support'},
        'limitations':['Similarity is not calibrated across models. The default 0.80 is a reference setting; inspect per-model setting sweeps before interpreting grouping differences.',
                      'All full-speech observations use identical canonical 16 kHz mono audio, with each model’s official feature preparation.',
                      'Current sample metrics are a retrospective numerical replay; transcript labels are the saved app output.',
                      'No accuracy ranking is established without independent held-out listening labels.']},
        'coverage':{'samples':len(source['samples']),'eligible':len(source['samples']),'meetings':len(source['meetings']),
                    'vector_bearing_meetings':len({s['meeting_id'] for s in source['samples']}),'models':len(entries)},
        'full_speech':full_metadata(source)['full_speech'],'methods':methods,'method_catalog':catalog,'scenarios':list(scenarios.values())}
    write_json(args.output/'results.json',result)


if __name__ == '__main__':
    main()
