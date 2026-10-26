#!/usr/bin/env python3
"""Compare HDBSCAN selection rules and matched nonoverlapping density controls.

Run each model through measure.py after embedding extraction finishes. All outputs
and caches are private experiment artifacts. This module never extracts audio.
"""
import argparse
from collections import Counter, defaultdict
import copy
import hashlib
import importlib.metadata
import json
import math
from pathlib import Path
import re
import shutil
import time

import numpy as np

from compare import assign_groups, changes
from full_compare import full_metrics, representatives, support_intervals
from model_compare import digest, graph_at, load_samples, validate_run, write_json

CLUSTER_SIZES = (5, 10, 20)
DENSITIES = (3, 5)  # Including self; contrib HDBSCAN receives one less.
SIMILARITIES = (.65, .75, .80)
SELECTIONS = ('eom', 'leaf')
DENSE_WORKING_BUDGET = 6 * 1024**3
MODEL_LABELS = {'wespeaker': 'WeSpeaker', 'redimnet_b6': 'ReDimNet B6',
                'redimnet_b3': 'ReDimNet B3', 'eres2netv2': 'ERes2NetV2 Large', 'campplus': 'CAM++ LM'}
MODEL_IDS = {'wespeaker':'community1-wespeaker-coreml', 'redimnet_b6':'redimnet2_b6_vb2_vox2_lm',
             'redimnet_b3':'redimnet2_b3_vb2_vox2_cnc2_lm', 'eres2netv2':'eres2netv2-w24s4ep4',
             'campplus':'wespeaker-campplus-lm'}
REFERENCES = [
    'https://hdbscan.readthedocs.io/en/latest/api.html',
    'https://hdbscan.readthedocs.io/en/latest/parameter_selection.html',
    'https://hdbscan.readthedocs.io/en/latest/prediction_tutorial.html',
    'https://scikit-learn.org/stable/modules/generated/sklearn.cluster.HDBSCAN.html',
]


def stable(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False)


def model_key(entry):
    key = entry.get('model_key') or entry['id'].removeprefix('global_dbscan_')
    if not re.fullmatch(r'[a-z0-9_]+', key) or key not in MODEL_LABELS:
        raise ValueError('Descriptor must identify one of the five supported model keys.')
    if entry.get('expected_model_id') != MODEL_IDS[key]:
        raise ValueError('Model key does not match its declared embedding identity.')
    return key


def nonoverlapping_positions(samples, indices):
    """Maximum disjoint context count, separately per source-content identity."""
    intervals = support_intervals(samples, indices)
    order = sorted(range(len(indices)), key=lambda i: (intervals[i][2], intervals[i][1], samples[indices[i]]['id']))
    last_end, selected = {}, []
    for position in order:
        file_key, start, end = intervals[position]
        if start >= last_end.get(file_key, -math.inf) - 1e-9:
            selected.append(position)
            last_end[file_key] = end
    return sorted(selected)


def selection_plan(samples, indices, mode):
    if mode == 'all':
        return list(range(len(indices)))
    if mode == 'nonoverlap':
        return nonoverlapping_positions(samples, indices)
    raise ValueError('Unknown fit cohort.')


def dense_working_estimate(vectors):
    """Conservative dense-matrix planning allowance, excluding runtime RSS."""
    return 3 * len(vectors)**2 * 8 + 2 * vectors.nbytes


def hdbscan_fit(vectors, selection, cluster_size, density, cache,
                mst_backend='generic', max_dense_bytes=DENSE_WORKING_BUDGET):
    import hdbscan
    from joblib import Memory
    if density < 2 or cluster_size < 2:
        raise ValueError('Density and minimum cluster size must be at least two.')
    if mst_backend not in ('generic','prims_kdtree') or max_dense_bytes < 1:
        raise ValueError('Choose a supported exact MST backend and a positive dense working budget.')
    count = len(vectors)
    if count < max(cluster_size, density):
        return dict(labels=np.full(count, -1, dtype=int), probabilities=np.zeros(count),
                    outliers=[None] * count, persistence={}, core=None, status='insufficient_observations',
                    mst_backend=None, dense_working_estimate_bytes=0)
    estimate=dense_working_estimate(vectors) if mst_backend=='generic' else 0
    if estimate > max_dense_bytes:
        raise ValueError('Dense HDBSCAN working estimate exceeds its budget; use --mst-backend prims_kdtree or explicitly increase --max-dense-bytes after checking memory.')
    model = hdbscan.HDBSCAN(min_cluster_size=cluster_size, min_samples=density - 1,
        metric='euclidean', algorithm=mst_backend, alpha=1., approx_min_span_tree=False,
        core_dist_n_jobs=1, cluster_selection_method=selection, allow_single_cluster=False,
        prediction_data=False, memory=Memory(location=str(cache), verbose=0)).fit(vectors)
    probabilities = np.asarray(model.probabilities_, dtype=float)
    if not np.isfinite(probabilities).all() or ((probabilities < 0) | (probabilities > 1)).any():
        raise ValueError('HDBSCAN returned invalid membership strengths.')
    # Degenerate hierarchies can lack finite GLOSH outlier scores. Preserve that
    # missing measurement instead of manufacturing an outlier probability.
    outliers = [float(value) if np.isfinite(value) else None for value in model.outlier_scores_]
    persistence = {int(label): float(value) if np.isfinite(value) else None
                   for label,value in enumerate(model.cluster_persistence_)}
    return dict(labels=model.labels_, probabilities=probabilities, outliers=outliers,
                persistence=persistence, core=None, status='complete', mst_backend=mst_backend,
                dense_working_estimate_bytes=estimate)


def stock_dbscan_fit(vectors, similarity, density, max_edges):
    from sklearn.cluster import DBSCAN
    from sklearn.neighbors import sort_graph_by_row_values
    if len(vectors) == 0:
        return dict(labels=np.empty(0,dtype=int), probabilities=None, outliers=[], persistence={}, core=set(), status='insufficient_observations')
    samples = [{'embedding': row} for row in vectors]
    graph = graph_at(samples, similarity, max_edges)
    graph.data = np.sqrt(np.maximum(0., 2. * (1. - graph.data)))
    graph.setdiag(0.)
    graph = sort_graph_by_row_values(graph, copy=True, warn_when_not_sorted=False)
    model = DBSCAN(eps=math.sqrt(2. * (1. - similarity)) + 1e-12,
                   min_samples=density, metric='precomputed', n_jobs=1).fit(graph)
    return dict(labels=model.labels_, probabilities=None, outliers=[None]*len(vectors),
                persistence={}, core=set(map(int,model.core_sample_indices_)), status='complete')


def assignments_for(samples, indices, members, selected, fit, prefix):
    fitted = {position: local for local,position in enumerate(selected)}
    groups = defaultdict(list)
    for position, aliases in enumerate(members):
        local = fitted.get(position)
        label = int(fit['labels'][local]) if local is not None else -1
        key = ('cluster',label) if local is not None and label >= 0 else ('unresolved',position)
        groups[key].extend(aliases)
    result = assign_groups(samples, list(groups.values()), prefix, cold=True)
    for position,aliases in enumerate(members):
        local = fitted.get(position)
        label = int(fit['labels'][local]) if local is not None else -1
        for index in aliases:
            row = result[samples[index]['id']]
            row.update(fit_role='fitted' if local is not None else 'overlap_omitted',
                       noise=bool(label < 0) if local is not None else None,
                       core=(local in fit['core']) if local is not None and fit['core'] is not None else None,
                       membership_confidence=float(fit['probabilities'][local]) if local is not None and fit['probabilities'] is not None else None,
                       outlier_score=fit['outliers'][local] if local is not None else None,
                       cluster_persistence=fit['persistence'].get(label) if label >= 0 else None)
            if local is None:
                row.update(state='excluded', omission_reason='overlapping_embedding_context')
    return result


def distribution(values):
    values = np.asarray([value for value in values if value is not None], dtype=float)
    if not len(values):
        return None
    return {name: float(np.quantile(values, fraction)) for name,fraction in [('minimum',0),('median',.5),('p90',.9),('maximum',1)]}


def metrics_for(samples, indices, assignments):
    metrics = full_metrics(assignments)
    physical = [assignments[samples[index]['id']] for index in indices]
    fitted = [row for row in physical if row['fit_role'] == 'fitted']
    grouped = Counter(row['group'] for row in fitted if row['noise'] is False)
    metrics.update(physical_observations=len(physical), fitted_physical_observations=len(fitted),
        omitted_physical_observations=len(physical)-len(fitted),
        fitted_samples=sum(row['fit_role']=='fitted' for row in assignments.values()),
        omitted_samples=sum(row['fit_role']=='overlap_omitted' for row in assignments.values()),
        fitted_noise_physical_observations=sum(row['noise'] is True for row in fitted),
        fitted_noise_fraction=sum(row['noise'] is True for row in fitted)/len(fitted) if fitted else None,
        largest_cluster_physical_observations=max(grouped.values(),default=0),
        membership_strength=distribution(row['membership_confidence'] for row in fitted if row['noise'] is False),
        outlier_score=distribution(row['outlier_score'] for row in fitted))
    return metrics


def read_labels(path, input_hash, samples):
    if path is None:
        return {}, None
    document = json.loads(Path(path).read_text())
    if document.get('source_input_sha256') != input_hash or document.get('kind') != 'independent_listening':
        raise ValueError('Quality labels must identify this input and independent listening judgments.')
    labels = document.get('labels', {})
    if not isinstance(labels,dict) or set(labels)-{sample['id'] for sample in samples}:
        raise ValueError('Quality labels contain unknown observation IDs.')
    if any(not isinstance(value,str) or not value.strip() for value in labels.values()):
        raise ValueError('Every quality label must contain a nonempty identity.')
    return labels, digest(path)


def quality_for(samples, indices, members, assignments, labels):
    if not labels:
        return dict(status='unavailable', reason='Independent identity judgments were not supplied; grouping coverage and membership strength do not measure speaker accuracy.')
    observations = []
    for representative,aliases in zip(indices,members):
        identities = {labels[samples[index]['id']] for index in aliases if samples[index]['id'] in labels}
        if len(identities) > 1:
            raise ValueError('Independent labels disagree for identical physical support.')
        row = assignments[samples[representative]['id']]
        if identities and row['fit_role']=='fitted':
            observations.append((next(iter(identities)),row['group'],row['noise']))
    pairs = lambda values: sum(value*(value-1)//2 for value in values)
    by_person, by_group, intersection = Counter(), Counter(), Counter()
    clustered_people = Counter()
    for person,group,noise in observations:
        by_person[person] += 1
        if not noise:
            by_group[group] += 1
            intersection[(person,group)] += 1
            clustered_people[person] += 1
    correct = pairs(intersection.values())
    predicted = pairs(by_group.values())
    same = pairs(by_person.values())
    clustered_same = pairs(clustered_people.values())
    return dict(status='measured', labeled_physical_observations=len(observations),
        false_merge_pairs=predicted-correct, false_split_cluster_pairs=clustered_same-correct,
        same_person_unresolved_pairs=same-clustered_same, missed_same_person_pairs=same-correct,
        pair_precision=correct/predicted if predicted else None, pair_recall=correct/same if same else None,
        scope='Labeled fitted physical observations only; algorithmic noise remains unresolved. Overlap omissions and exact aliases do not inflate pair counts.')


def churn(before, after):
    result = changes(before, after)
    shared = set(before)&set(after)
    result.update(clustered_to_noise=sum(before[key]['noise'] is False and after[key]['noise'] is True for key in shared),
                  noise_to_clustered=sum(before[key]['noise'] is True and after[key]['noise'] is False for key in shared),
                  fitted_to_omitted=sum(before[key]['fit_role']=='fitted' and after[key]['fit_role']=='overlap_omitted' for key in shared),
                  omitted_to_fitted=sum(before[key]['fit_role']=='overlap_omitted' and after[key]['fit_role']=='fitted' for key in shared))
    return result


def policy_for(mode, selection=None, cluster_size=None, density=3, similarity=None,
               mst_backend='generic', max_dense_bytes=DENSE_WORKING_BUDGET):
    algorithm = ('hdbscan' if mode=='all' else 'hdbscan_nonoverlap') if selection else 'dbscan_nonoverlap'
    return dict(algorithm=algorithm, fit_cohort=mode, selection_method=selection,
        min_cluster_size=cluster_size, min_samples=density,
        min_samples_includes_self=True, contrib_min_samples=density-1 if selection else None,
        similarity=similarity, distance='euclidean_on_unit_l2',
        distance_definition='sqrt(2 * (1 - cosine_similarity))',
        density='unique_physical_windows' if mode=='all' else 'globally_nonoverlapping_embedding_contexts',
        overlap_limitation='Overlapping distinct windows can increase density.' if mode=='all' else 'Overlapping omitted windows remain excluded from fit and separate from algorithmic noise.',
        approx_min_span_tree=False if selection else None, allow_single_cluster=False if selection else None,
        mst_backend=mst_backend if selection else None,
        dense_working_budget_bytes=max_dense_bytes if selection and mst_backend=='generic' else None,
        dense_working_estimate='3 * observations^2 * 8 + 2 * input_array_bytes; planning allowance excludes runtime allocations and is not a process RSS cap.' if selection and mst_backend=='generic' else None,
        cluster_selection_epsilon=0. if selection else None,
        membership_interpretation='HDBSCAN membership strength is not a calibrated speaker identity probability.' if selection else None)


def fit_case(samples, policy, cache, max_edges):
    indices,members = representatives(samples)
    selected = selection_plan(samples,indices,policy['fit_cohort'])
    vectors = np.ascontiguousarray([samples[indices[position]]['embedding'] for position in selected],dtype=np.float64)
    started = time.monotonic()
    if policy['selection_method']:
        fit = hdbscan_fit(vectors,policy['selection_method'],policy['min_cluster_size'],policy['min_samples'],cache,
                          policy['mst_backend'],policy.get('dense_working_budget_bytes') or DENSE_WORKING_BUDGET)
    else:
        fit = stock_dbscan_fit(vectors,policy['similarity'],policy['min_samples'],max_edges)
    assignments = assignments_for(samples,indices,members,selected,fit,policy['algorithm'])
    metrics=metrics_for(samples,indices,assignments)
    if policy['selection_method']:
        metrics['core_samples']=None
        metrics['cluster_persistence']=distribution(fit['persistence'].values())
    return assignments,metrics,indices,members,dict(
        fit_seconds=time.monotonic()-started, fit_status=fit['status'], cluster_persistence=fit['persistence'],
        mst_backend=fit.get('mst_backend'),dense_working_estimate_bytes=fit.get('dense_working_estimate_bytes'))


def arrival_plans(source, samples):
    meetings=sorted(source['meetings'],key=lambda row:(row['meeting_order'],row['id']))
    meeting_sizes=sorted({min(count,len(meetings)) for count in (5,10,15,20)}|{len(meetings)})
    order=sorted(range(len(samples)),key=lambda i:(samples[i]['meeting_order'],samples[i]['support_spans'][0]['start'],samples[i]['id']))
    batch=max(1,math.ceil(len(samples)/8))
    return [('growing_meetings',[(count,[sample for sample in samples if sample['meeting_id'] in {row['id'] for row in meetings[:count]}]) for count in meeting_sizes]),
            ('growing_samples',[(step,[samples[i] for i in sorted(order[:stop])]) for step,stop in enumerate(range(batch,len(samples)+batch,batch),1)])]


def arrival_results(source,samples,method,variant,policy,cache,max_edges,full):
    output=[]
    for name,plan in arrival_plans(source,samples):
        previous,checkpoints={},[]
        for step,arrived in plan:
            if len(arrived)==len(samples):
                current,metrics=full
            else:
                current,metrics,*_=fit_case(arrived,policy,cache,max_edges)
            indices,_=representatives(arrived)
            physical={arrived[index]['density_key']:current[arrived[index]['id']] for index in indices}
            checkpoints.append(dict(step=step,samples=len(current),metrics=metrics,change=churn(previous,physical)))
            previous=physical
        output.append(dict(name=name,method=method,variant=variant,checkpoints=checkpoints))
    return output


def run_model(input_path,manifest_path,key,output,labels_path=None,max_edges=20_000_000,benchmark=False,
              mst_backend='generic',max_dense_bytes=DENSE_WORKING_BUDGET):
    input_path,manifest_path,output=Path(input_path),Path(manifest_path),Path(output)
    input_hash,manifest_hash=digest(input_path),digest(manifest_path)
    source=json.loads(input_path.read_text())
    entries=json.loads(manifest_path.read_text())
    matching=[entry for entry in entries if model_key(entry)==key]
    if len(matching)!=1:
        raise ValueError('Select exactly one declared embedding model.')
    entry=matching[0]
    summary,provenance=validate_run(source,entry,input_hash)
    embeddings_hash=digest(entry['embeddings'])
    samples=load_samples(source,entry['embeddings'],entry['expected_model_id'])
    labels,labels_hash=read_labels(labels_path,input_hash,samples)
    output.mkdir(parents=True,exist_ok=True)
    cache=output/'cache'/key
    metadata=dict(source_input_sha256=input_hash,models_manifest_sha256=manifest_hash,
        embeddings_sha256=embeddings_hash,source_sha256=digest(Path(__file__)),
        model_key=key,expected_model_id=entry['expected_model_id'],labels_sha256=labels_hash,
        provenance=provenance,reference_sources=REFERENCES,mst_backend=mst_backend,
        dense_working_budget_bytes=max_dense_bytes if mst_backend=='generic' else None,
        versions={name:importlib.metadata.version(name) for name in ('hdbscan','scikit-learn','numpy','scipy','joblib')})
    marker=output/'model-results'/(key+'.json')
    if marker.exists():
        raise ValueError('Model result already exists; preserve it and use a new run directory.')
    methods,catalog,scenarios={ },[],[]
    configurations=[]
    for mode in ('all','nonoverlap'):
        method=f'global_hdbscan_{key}' if mode=='all' else f'global_hdbscan_nonoverlap_{key}'
        variants=[]
        for cluster_size in CLUSTER_SIZES:
            for density in DENSITIES:
                for selection in SELECTIONS:
                    variant=f'{mode}_{selection}_c{cluster_size:03d}_m{density:03d}'
                    label=f'{"All Windows" if mode=="all" else "Nonoverlapping Contexts"} · {selection.upper() if selection=="eom" else "Leaf"} · minimum cluster {cluster_size} · density {density}'
                    configurations.append((method,variant,label,policy_for(mode,selection,cluster_size,density,
                        mst_backend=mst_backend,max_dense_bytes=max_dense_bytes)))
        catalog.append(dict(id=method,model_key=key,model_label=MODEL_LABELS[key],
            algorithm='hdbscan' if mode=='all' else 'hdbscan_nonoverlap',
            algorithm_label='HDBSCAN' if mode=='all' else 'HDBSCAN · Nonoverlapping Contexts',
            label=f'{MODEL_LABELS[key]} · HDBSCAN'+(' · Nonoverlapping Contexts' if mode!='all' else ''),
            short_label=MODEL_LABELS[key]+' · HDBSCAN',default_variant=f'{mode}_eom_c005_m003',variants=variants))
    method=f'global_dbscan_nonoverlap_{key}'
    catalog.append(dict(id=method,model_key=key,model_label=MODEL_LABELS[key],algorithm='dbscan_nonoverlap',
        algorithm_label='DBSCAN · Nonoverlapping Contexts',label=f'{MODEL_LABELS[key]} · DBSCAN · Nonoverlapping Contexts',
        short_label=MODEL_LABELS[key]+' · DBSCAN Control',default_variant='nonoverlap_s080_m003',variants=[],skipped_settings=[]))
    for similarity in SIMILARITIES:
        for density in DENSITIES:
            variant=f'nonoverlap_s{round(similarity*100):03d}_m{density:03d}'
            configurations.append((method,variant,f'Nonoverlapping Contexts · similarity {similarity:.2f} · density {density}',policy_for('nonoverlap',density=density,similarity=similarity)))
    for method,variant,label,policy in configurations:
        item=next(item for item in catalog if item['id']==method)
        try:
            assignments,metrics,indices,members,details=fit_case(samples,policy,cache,max_edges)
        except ValueError as error:
            if policy['selection_method'] is None and 'resource limit' in str(error):
                item['skipped_settings'].append(dict(id=variant,label=label,status='resource_limit',reason=str(error)))
                if variant==item['default_variant']:
                    raise ValueError('Matched DBSCAN default exceeds the resource limit.') from error
                continue
            raise
        value=dict(method=method,variant=variant,label=label,description=label,assignments=assignments,
                   metrics=metrics,policy=policy,quality=quality_for(samples,indices,members,assignments,labels),**details)
        relative=Path('variants')/method/(variant+'.json')
        write_json(output/relative,value)
        item['variants'].append(dict(id=variant,label=label,description=label,**policy,metrics=metrics,
                                    quality=value['quality'],path=str(relative),sha256=digest(output/relative)))
        if variant==item['default_variant']:
            methods[method]=value
        if not benchmark and ((policy['selection_method'] and policy['min_cluster_size']==5 and policy['min_samples']==3)
                              or variant==item['default_variant']):
            scenarios.extend(arrival_results(source,samples,method,variant,policy,cache,max_edges,(assignments,metrics)))
        print(stable(dict(model=key,variant=variant,fit_seconds=details['fit_seconds'],metrics=metrics)),flush=True)
    current_summary,current_provenance=validate_run(source,entry,input_hash)
    if (digest(input_path)!=input_hash or digest(manifest_path)!=manifest_hash
            or digest(entry['embeddings'])!=embeddings_hash or current_provenance!=provenance or current_summary!=summary
            or (labels_path and digest(labels_path)!=labels_hash)):
        raise ValueError('Clustering inputs changed during evaluation.')
    result=dict(schema_version=1,status='benchmark' if benchmark else 'complete',metadata=metadata,
        methods=methods,method_catalog=catalog,scenarios=scenarios,
        limitations=[
            'Primary HDBSCAN fits every unique physical context; distinct overlapping contexts can still increase density.',
            'Matched controls fit the same deterministic maximum nonoverlapping context set. Omitted contexts remain represented, excluded from fitting, and separate from algorithmic noise.',
            'Euclidean distance on unit vectors preserves cosine neighbor order; its nonlinear distance scale can change HDBSCAN cluster stability.',
            'Membership strength, persistence, coverage, and agreement with another algorithm do not establish speaker identity accuracy.',
            'Approximate prediction is not used: arrival checkpoints refit arrived evidence and can create, merge, or split clusters.'])
    write_json(marker,result)
    return result


def attach(input_path,manifest_path,output,review_root,resource_paths=()):
    input_path,manifest_path,output,review_root=map(Path,(input_path,manifest_path,output,review_root))
    input_hash,manifest_hash=digest(input_path),digest(manifest_path)
    source=json.loads(input_path.read_text())
    entries=json.loads(manifest_path.read_text())
    keys=[model_key(entry) for entry in entries]
    if len(set(keys))!=len(keys) or set(keys)!=set(MODEL_LABELS):
        raise ValueError('Attachment requires exactly the five declared embedding models.')
    result_path=review_root/'results.json'
    review_hash=digest(result_path)
    result=json.loads(result_path.read_text())
    if result['metadata'].get('full_speech_input_sha256')!=input_hash:
        raise ValueError('Review results belong to another full-speech input.')
    source_path=review_root/'review-input.json'
    if result['metadata']['input_sha256']!=digest(source_path):
        raise ValueError('Review input changed.')
    runs=[]
    for entry,key in zip(entries,keys):
        _,provenance=validate_run(source,entry,input_hash)
        previous=next((item for item in result['method_catalog'] if item['id']==entry['id']),None)
        if (previous is None or previous.get('embeddings_sha256')!=digest(entry['embeddings'])
                or previous.get('provenance',{}).get('prepared_sha256')!=provenance['prepared_sha256']
                or previous.get('embedding_metadata',{}).get('model_metadata',{}).get('model_id')!=entry['expected_model_id']):
            raise ValueError('HDBSCAN and existing DBSCAN results must use identical typed embeddings and canonical preparation.')
        path=output/'model-results'/(key+'.json')
        run=json.loads(path.read_text())
        metadata=run['metadata']
        if (run['status']!='complete' or metadata['source_input_sha256']!=input_hash
                or metadata['models_manifest_sha256']!=manifest_hash
                or metadata['embeddings_sha256']!=digest(entry['embeddings'])
                or metadata['expected_model_id']!=entry['expected_model_id'] or metadata['model_key']!=key
                or metadata['provenance']!=provenance or metadata['source_sha256']!=digest(Path(__file__))):
            raise ValueError('HDBSCAN result is incomplete or stale.')
        runs.append((entry,key,path,run))
    if len({run['metadata']['labels_sha256'] for _,_,_,run in runs})!=1:
        raise ValueError('Every model must use the same independent quality labels.')
    if len({run['metadata']['provenance']['prepared_sha256'] for _,_,_,run in runs})!=1:
        raise ValueError('Every model must use the same canonical preparation.')
    # Validate the entire batch before touching the running review. Existing
    # variants are immutable; a corrected run uses a fresh review directory.
    copies=[]
    run_hashes={path:digest(path) for _,_,path,_ in runs}
    expected_ids={sample['id'] for sample in source['samples']}
    for _,key,_,run in runs:
        methods={f'global_hdbscan_{key}',f'global_hdbscan_nonoverlap_{key}',f'global_dbscan_nonoverlap_{key}'}
        if set(run['methods'])!=methods or {item['id'] for item in run['method_catalog']}!=methods:
            raise ValueError('Clustering result has incomplete or mismatched methods.')
        for item in run['method_catalog']:
            if item['model_key']!=key or len({variant['id'] for variant in item['variants']})!=len(item['variants']):
                raise ValueError('Clustering catalog has duplicate variants or mismatched model identity.')
            default_found=False
            for variant in item['variants']:
                relative=Path(variant['path'])
                if (not re.fullmatch(r'[a-z0-9_]+',variant['id'])
                        or relative.parts!=('variants',item['id'],variant['id']+'.json')):
                    raise ValueError('Invalid clustering variant path.')
                variant_source=output/relative
                variant_source.resolve().relative_to(output.resolve())
                if digest(variant_source)!=variant['sha256']:
                    raise ValueError('Clustering variant changed.')
                value=json.loads(variant_source.read_text())
                if value['method']!=item['id'] or value['variant']!=variant['id'] or set(value['assignments'])!=expected_ids:
                    raise ValueError('Clustering variant has incomplete coverage or mismatched identity.')
                if variant['id']==item['default_variant']:
                    default_found=True
                    if value!=run['methods'][item['id']]:
                        raise ValueError('Default method differs from its declared variant.')
                destination=review_root/relative
                destination.resolve().relative_to(review_root.resolve())
                if destination.is_symlink() or (destination.exists() and digest(destination)!=variant['sha256']):
                    raise ValueError('Existing clustering variant differs; use a new review directory for a corrected run.')
                copies.append((variant_source,destination,variant['sha256']))
            if not default_found:
                raise ValueError('Clustering method has no complete default variant.')
    for variant_source,destination,expected_hash in copies:
        if destination.exists():
            continue
        destination.parent.mkdir(parents=True,exist_ok=True)
        temporary=destination.with_suffix('.json.partial')
        shutil.copyfile(variant_source,temporary)
        if digest(temporary)!=expected_hash:
            raise ValueError('Clustering variant changed while being copied.')
        if destination.exists():
            if digest(destination)!=expected_hash:
                raise ValueError('Review variant changed during attachment.')
            temporary.unlink()
        else:
            temporary.replace(destination)
    for item in result.get('method_catalog',[]):
        if item['id']=='current_local_library':
            item.update(model_key='current_local_library',model_label='Current Saved',algorithm='saved',algorithm_label='Saved App Result')
        else:
            entry=next((entry for entry in entries if entry['id']==item['id']),None)
            if entry:
                key=model_key(entry)
                item.update(model_key=key,model_label=MODEL_LABELS[key],algorithm='dbscan',algorithm_label='DBSCAN')
    for entry,key,path,run in runs:
        for item in run['method_catalog']:
            result['method_catalog']=[old for old in result['method_catalog'] if old['id']!=item['id']]+[item]
        result['methods'].update(run['methods'])
        # Explicitly retain both EOM and leaf arrival results. Existing clients
        # continue to find each method's default under the methods mapping.
        for scenario in run['scenarios']:
            target=next((old for old in result['scenarios'] if old['name']==scenario['name']),None)
            if target is None:
                target=dict(name=scenario['name'],checkpoints=[])
                result['scenarios'].append(target)
            default=next(item['default_variant'] for item in run['method_catalog'] if item['id']==scenario['method'])
            for point in scenario['checkpoints']:
                checkpoint=next((old for old in target['checkpoints'] if old['step']==point['step']),None)
                if checkpoint is None:
                    checkpoint=dict(step=point['step'],samples=point['samples'],methods={})
                    target['checkpoints'].append(checkpoint)
                value={name:point[name] for name in ('metrics','change')}
                checkpoint.setdefault('variant_methods',{}).setdefault(scenario['method'],{})[scenario['variant']]=value
                if scenario['variant']==default:
                    checkpoint['methods'][scenario['method']]=value
            target['checkpoints'].sort(key=lambda point:point['step'])
        reference=result['methods'].get(entry['id'],{}).get('assignments')
        if reference:
            samples=load_samples(source,entry['embeddings'],entry['expected_model_id'])
            indices,_=representatives(samples)
            reference_physical={samples[i]['density_key']:reference[samples[i]['id']] for i in indices}
            for method,value in run['methods'].items():
                physical={samples[i]['density_key']:value['assignments'][samples[i]['id']] for i in indices}
                result['methods'][method]['reference_disagreement']=dict(
                    **changes(reference_physical,physical),
                    scope='Physical-observation co-membership disagreement with the existing custom DBSCAN default; density rules differ. This is not an accuracy score.')
    receipts=[dict(path=str(path),sha256=digest(path),receipt=json.loads(Path(path).read_text())) for path in resource_paths]
    result['hdbscan_resources']=dict(runs=[dict(model_key=key,sha256=digest(path),metadata=run['metadata']) for _,key,path,run in runs],
        measurements=receipts,limitations=runs[0][3]['limitations'],references=REFERENCES)
    result['metadata']['hdbscan_comparison']=dict(input_sha256=input_hash,models_manifest_sha256=manifest_hash,
        source_sha256=digest(Path(__file__)),models=len(runs),algorithms=['hdbscan','hdbscan_nonoverlap','dbscan_nonoverlap'])
    if (digest(result_path)!=review_hash or digest(input_path)!=input_hash
            or digest(manifest_path)!=manifest_hash or digest(source_path)!=result['metadata']['input_sha256']
            or any(digest(path)!=value for path,value in run_hashes.items())
            or any(digest(destination)!=expected for _,destination,expected in copies)):
        raise ValueError('Review or clustering inputs changed during attachment.')
    write_json(result_path,result)
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='command',required=True)
    run=sub.add_parser('run')
    run.add_argument('--model-key',choices=tuple(MODEL_LABELS),required=True)
    run.add_argument('--labels',type=Path)
    run.add_argument('--max-neighbor-edges',type=int,default=20_000_000)
    run.add_argument('--mst-backend',choices=['generic','prims_kdtree'],default='generic')
    run.add_argument('--max-dense-bytes',type=int,default=DENSE_WORKING_BUDGET,
                     help='Dense working planning budget; excludes runtime allocations and does not cap process RSS.')
    run.add_argument('--benchmark',action='store_true',help='Omit arrival replays; result cannot be attached as complete.')
    collect=sub.add_parser('attach')
    collect.add_argument('--review-root',type=Path,required=True)
    collect.add_argument('--resource-receipt',type=Path,action='append',default=[])
    for command in (run,collect):
        command.add_argument('--input',type=Path,required=True)
        command.add_argument('--models',type=Path,required=True)
        command.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    if args.command=='run':
        run_model(args.input,args.models,args.model_key,args.output,args.labels,args.max_neighbor_edges,args.benchmark,
                  args.mst_backend,args.max_dense_bytes)
    else:
        attach(args.input,args.models,args.output,args.review_root,args.resource_receipt)


if __name__=='__main__':
    main()
