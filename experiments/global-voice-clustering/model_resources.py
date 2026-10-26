#!/usr/bin/env python3
"""Attach measured resources and explicitly scoped projections to review results.

--models is an explicit JSON array. Each entry has model_id, summary,
extraction_receipt, extraction_provenance; alternatives can also supply conversion, conversion_receipt,
predictions (array), prediction_receipts (array), private_prediction, and
private_fixtures (the corresponding reference fixture manifest).
All paths are resolved from the working directory. Receipts remain under tmp/.
"""
import argparse
from bisect import bisect_left
from collections import Counter, defaultdict
import hashlib
import json
import math
from pathlib import Path
import statistics


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def read(path, sources):
    path = Path(path).resolve()
    value = json.loads(path.read_text())
    sources[str(path)] = digest(path)
    return value


def interpolate(points, duration):
    """Interpolate measured durations; preserve unsupported durations as missing."""
    if any(not math.isfinite(float(value)) or value < 0 for value in points.values()):
        raise ValueError('Measured component latencies must be finite and nonnegative.')
    keys = sorted(points)
    if not keys or not math.isfinite(duration) or duration < keys[0] or duration > keys[-1]:
        return None
    upper = bisect_left(keys, duration)
    if keys[upper] == duration:
        return points[duration]
    left, right = keys[upper - 1], keys[upper]
    ratio = (duration - left) / (right - left)
    return points[left] + ratio * (points[right] - points[left])


def project(histogram, frontend, backbone, normalization):
    totals = dict(frontend_seconds=0., backbone_seconds=0., normalization_seconds=0.)
    missing = 0
    for duration, count in histogram.items():
        front, back = interpolate(frontend, duration), interpolate(backbone, duration)
        if front is None or back is None:
            missing += count
            continue
        totals['frontend_seconds'] += count * front
        totals['backbone_seconds'] += count * back
        totals['normalization_seconds'] += count * normalization
    if missing:
        return {'projected_jobs': sum(histogram.values()) - missing, 'unprojected_jobs': missing,
                'serial_seconds': None, **{key: None for key in totals}}
    return {'projected_jobs': sum(histogram.values()), 'unprojected_jobs': 0,
            'serial_seconds': sum(totals.values()), **totals}


def peak_mb(receipt):
    value = receipt.get('cpu_and_process_peak', {}).get('peak_rss_bytes')
    return value / 1e6 if value is not None else None


def valid_stage(receipt):
    return receipt.get('status') == 'completed' and receipt.get('exit_status') == 0


def invocation(receipt, script, stage):
    """Read the measured child argv, excluding uv's environment arguments."""
    command = receipt.get('command', [])
    matches = [index for index, value in enumerate(command) if Path(value).name == script]
    if len(matches) != 1 or command[matches[0] + 1:matches[0] + 2] != [stage]:
        raise ValueError(f'Resource receipt does not measure {script} {stage}.')
    arguments = command[matches[0] + 2:]
    def option(name, default=None):
        indices = [index for index, value in enumerate(arguments) if value == name]
        if not indices:
            return default
        if len(indices) != 1 or indices[0] + 1 >= len(arguments):
            raise ValueError('Ambiguous measured command arguments.')
        return arguments[indices[0] + 1]
    def path(name, default=None):
        value = option(name, default)
        if value is None:
            raise ValueError(f'Measured command lacks {name}.')
        target = Path(value)
        return target.resolve() if target.is_absolute() else (Path(receipt['cwd']) / target).resolve()
    return option, path


def bind_extraction(receipt, entry, prepared_sha256, sources):
    _, path = invocation(receipt, 'model_extract.py', 'extract')
    if path('--output') != Path(entry['summary']).resolve().parent:
        raise ValueError('Extraction receipt output differs from the extraction summary.')
    prepared_path = path('--prepared')
    read(prepared_path, sources)
    if digest(prepared_path) != prepared_sha256:
        raise ValueError('Extraction receipt uses a different prepared audio plan.')


def bind_conversion(receipt, entry, conversion):
    option, path = invocation(receipt, 'coreml_benchmark.py', 'convert')
    if (path('--output') != Path(entry['conversion']).resolve().parent
            or option('--model-id') != conversion.get('adapter_metadata', {}).get('model_id')
            or option('--precision', 'FLOAT16') != conversion.get('conversion_precision', 'FLOAT16')):
        raise ValueError('Conversion resource receipt differs from the supplied model export.')


def bind_prediction(receipt, allowed_predictions, sources):
    option, path = invocation(receipt, 'coreml_benchmark.py', 'predict')
    output = path('--output')
    units, label = option('--compute-units', 'ALL'), option('--run-label', '')
    suffix = '-' + label if label else ''
    predicted_path = output / f'prediction-{units}{suffix}.json'
    if predicted_path not in allowed_predictions:
        raise ValueError('Runtime resource receipt is not bound to a supplied prediction result.')
    prediction = read(predicted_path, sources)
    if (prediction.get('compute_units') != 'ALL' or units != 'ALL'
            or prediction.get('run_label', '') != label or not label.startswith('native')
            or prediction.get('case_label') != option('--case-label')):
        raise ValueError('Runtime resource receipt does not match native ALL prediction settings.')
    manifest = path('--fixtures-manifest', str(output / 'conversion.json'))
    read(manifest, sources)
    if digest(manifest) != prediction.get('fixture_manifest_sha256'):
        raise ValueError('Prediction resource receipt uses a different fixture manifest.')
    return prediction


def assemble(results, prepared, entries, frontend_receipt, sources, additional_receipts=(), prepared_sha256=None):
    if not prepared_sha256:
        raise ValueError('Provide the prepared audio file hash.')
    if frontend_receipt.get('status') != 'complete' or not frontend_receipt.get('audio_sha256'):
        raise ValueError('Frontend measurement receipt did not complete successfully.')
    if results['metadata']['full_speech_input_sha256'] != prepared['provenance']['input_sha256']:
        raise ValueError('Prepared audio and review results belong to different inputs.')
    histogram = Counter(job['sample_count'] / 16000 for job in prepared['jobs'])
    frontend_models = {model['model_id']: model for model in frontend_receipt.get('models', [])}
    if frontend_receipt.get('threads') != 4:
        raise ValueError('Frontend timing must use four CPU threads.')
    measured, coreml = [], []
    stages = [read(path, sources) for path in additional_receipts]
    for entry in entries:
        summary = read(entry['summary'], sources)
        extraction = read(entry['extraction_receipt'], sources)
        metadata = summary['model_metadata']
        provenance = read(entry['extraction_provenance'], sources)
        if provenance.get('prepared_sha256') != prepared_sha256 or provenance.get('model_metadata') != metadata:
            raise ValueError('Extraction provenance differs from the prepared plan or summary metadata.')
        bind_extraction(extraction, entry, prepared_sha256, sources)
        if (metadata['model_id'] != entry['model_id'] or not summary.get('complete')
                or summary.get('unique_jobs') != len(prepared['jobs'])
                or summary.get('expected_rows') != len(prepared['aliases']) or not valid_stage(extraction)):
            raise ValueError('Full extraction resource receipt is incomplete or belongs to a different model.')
        stages.append(extraction)
        checkpoint_bytes = metadata.get('checkpoint_bytes', metadata.get('model_bytes'))
        measured.append(dict(model_id=entry['model_id'], backend=metadata.get('backend', metadata.get('device')),
                             unique_jobs=summary['unique_jobs'], load_seconds=summary['load_seconds'],
                             extraction_attempt_wall_seconds=extraction['wall_seconds'],
                             new_inference_seconds=summary['new_inference_seconds'],
                             checkpoint_mb=checkpoint_bytes/1e6 if checkpoint_bytes is not None else None,
                             extraction_peak_process_mb=peak_mb(extraction),
                             scope='Measured extraction process; includes its implementation and framework. Resumed inference time covers newly processed batches only.'))
        if not entry.get('conversion'):
            coreml.append(dict(model_id=entry['model_id'], status='Measured installed waveform pipeline',
                               package_mb=checkpoint_bytes/1e6 if checkpoint_bytes is not None else None,
                               measured_extraction_attempt_seconds=extraction['wall_seconds'],
                               runtime_peak_process_mb=peak_mb(extraction),
                               projection_serial_seconds=None,
                               scope='Installed frontend and embedding pipeline. Latest attempt wall time includes loading and cached-work validation; it is not the cost of all attempts.'))
            continue
        conversion = read(entry['conversion'], sources)
        conversion_stage = read(entry['conversion_receipt'], sources)
        stages.append(conversion_stage)
        bind_conversion(conversion_stage, entry, conversion)
        if conversion.get('adapter_metadata', {}).get('checkpoint_sha256') != metadata.get('checkpoint_sha256'):
            raise ValueError('Core ML conversion checkpoint differs from the extraction model.')
        known_package_sizes = [case['package_bytes'] for case in conversion.get('cases', []) if case.get('package_bytes') is not None]
        row = dict(model_id=entry['model_id'], precision=conversion.get('conversion_precision', 'FLOAT16'),
                   status='Pending numerical validation', package_mb=max(known_package_sizes)/1e6 if known_package_sizes else None,
                   conversion_wall_seconds=conversion_stage.get('wall_seconds'),
                   conversion_peak_process_mb=peak_mb(conversion_stage), runtime_peak_process_mb=None,
                   private_min_cosine=None, projection_serial_seconds=None,
                   scope='Fixed feature backbone; waveform frontend and L2 normalization measured separately. Runtime process RSS excludes device allocations and separate Core ML/ANE services. Conversion peak is separate from runtime.')
        row['runtime_measurement_scope'] = entry.get('runtime_scope', 'See bound native prediction receipts; process RSS excludes device allocations and external services.')
        package_sizes = {}
        for case in conversion.get('cases', []):
            if case.get('package'):
                package_sizes[case['package']] = max(package_sizes.get(case['package'], 0), case.get('package_bytes', 0))
        row['fixed_shape_package_count'] = len(package_sizes)
        row['all_fixed_shape_packages_mb'] = sum(package_sizes.values())/1e6 if package_sizes else None
        precision = row['precision'].lower()
        weight_bytes = conversion.get('weight_storage_estimate', {}).get(precision + '_parameter_bytes')
        row['shared_weight_payload_mb_estimate'] = weight_bytes/1e6 if weight_bytes is not None else None
        row['packaging_scope'] = 'Single-shape package_mb versus sum of separate fixed-shape packages, which duplicate weights. Shared-weight payload is a parameter-only estimate; a flexible-shape 2–5-second production package has not been built.'
        points, runtime_peaks = {}, []
        case_durations = {case['label']: case['sample_count']/16000 for case in conversion.get('cases', [])}
        valid = conversion.get('status') == 'complete' and valid_stage(conversion_stage)
        for path in entry.get('predictions', []):
            prediction = read(path, sources)
            native = prediction.get('run_label', '').startswith('native')
            valid = valid and prediction.get('status') == 'complete' and native
            for case in prediction.get('cases', []):
                valid = valid and case.get('parity_pass') is True
                duration = case_durations.get(case['label'])
                if case.get('parity_pass') and native and prediction.get('status') == 'complete' and duration is not None:
                    points[duration] = case['warm_median_seconds']
        allowed_predictions = {Path(path).resolve() for path in entry.get('predictions', [])}
        if entry.get('private_prediction'):
            allowed_predictions.add(Path(entry['private_prediction']).resolve())
        for path in entry.get('prediction_receipts', []):
            receipt = read(path, sources)
            stages.append(receipt)
            bound_prediction = bind_prediction(receipt, allowed_predictions, sources)
            if (valid_stage(receipt) and bound_prediction.get('status') == 'complete'
                    and bool(bound_prediction.get('cases')) and all(case.get('parity_pass') is True for case in bound_prediction.get('cases', []))) and peak_mb(receipt) is not None:
                runtime_peaks.append(peak_mb(receipt))
        row['runtime_peak_process_mb'] = max(runtime_peaks) if runtime_peaks else None
        private = read(entry['private_prediction'], sources) if entry.get('private_prediction') else None
        fixtures = read(entry['private_fixtures'], sources) if entry.get('private_fixtures') else None
        private_valid = bool(private and fixtures and private.get('fixture_manifest_sha256') == digest(entry['private_fixtures'])
                             and fixtures.get('source_conversion_sha256') == digest(entry['conversion'])
                             and fixtures.get('audio_sha256') == frontend_receipt.get('audio_sha256')
                             and fixtures.get('status') == 'complete'
                             and len(private.get('cases', [])) == len(fixtures.get('cases', []))
                             and {case['label'] for case in private.get('cases', [])} == {case['label'] for case in fixtures.get('cases', [])}
                             and private.get('status') == 'complete' and private.get('run_label', '').startswith('native')
                             and private.get('compute_units') == 'ALL' and private.get('cases')
                             and all(case.get('parity_pass') is True for case in private['cases']))
        if private and private.get('cases'):
            row['private_min_cosine'] = min(case['parity']['cosine'] for case in private['cases'])
        if private_valid:
            durations = {case['label']: case['sample_count']/16000 for case in fixtures['cases']}
            grouped_private = defaultdict(list)
            for case in private['cases']:
                grouped_private[durations[case['label']]].append(case['warm_median_seconds'])
            points = {duration: statistics.median(values) for duration, values in grouped_private.items()}
        else:
            points = {}
        valid = valid and set(points) == {2., 3., 5.}
        for duration in (2., 3., 5.):
            row[f'warm_{duration:g}s_ms'] = points.get(duration, 0)*1000 if duration in points else None
        front = frontend_models.get(entry['model_id'])
        if not valid:
            row['status'] = 'Export parity failed or native measurements incomplete'
            # Failed-parity timing cannot become a performance recommendation.
            for duration in (2, 3, 5):
                row[f'warm_{duration}s_ms'] = None
        elif not private_valid:
            row['status'] = 'Private parity pending or failed; projection withheld'
            for duration in (2, 3, 5):
                row[f'warm_{duration}s_ms'] = None
        elif not front or front.get('status') != 'complete':
            row['status'] = 'Frontend measurements pending; projection withheld'
        else:
            if front['cpu_metadata']['checkpoint_sha256'] != metadata.get('checkpoint_sha256'):
                raise ValueError('Frontend measurements use a different checkpoint.')
            grouped = defaultdict(list)
            for case in front['cases']:
                grouped[case['seconds']].append(case['frontend_median_seconds'])
            frontend_points = {duration: statistics.median(values) for duration, values in grouped.items()}
            projection = project(histogram, frontend_points, points, front['normalization_median_seconds'])
            row.update(status='Measured components; serial interpolation projection',
                       projection_serial_seconds=projection['serial_seconds'],
                       projected_frontend_seconds=projection['frontend_seconds'],
                       projected_backbone_seconds=projection['backbone_seconds'],
                       projected_normalization_seconds=projection['normalization_seconds'],
                       projected_jobs=projection['projected_jobs'], unprojected_jobs=projection['unprojected_jobs'],
                       projection_method='Sum over actual unique-job duration histogram. Linear interpolation between private-window native 2/3/5-second medians; four-thread CPU frontend + warm Core ML backbone + L2 normalization. No overlap, batching, cold compilation, new-shape specialization, loading, decode or I/O. Outside-range durations are withheld. This is a hybrid prototype estimate, not a native-app measurement.')
        coreml.append(row)
    results['model_resources'] = measured
    results['coreml_resources'] = coreml
    # Remove a superseded alias so the UI reads this run's explicit measurements.
    results.pop('coreml_projections', None)
    resources = results.get('resources', {})
    existing = resources if isinstance(resources, list) else resources.get('stages', [])
    by_attempt = {}
    for stage in existing + stages:
        identity = (stage.get('stage'), stage['started_at']) if stage.get('started_at') else json.dumps(stage, sort_keys=True)
        by_attempt[identity] = stage
    results['resources'] = {'stages': list(by_attempt.values()),
                            'scope': 'Process receipts include successful and failed stages. Shared ANE/compiler service and device memory are excluded; conversion and runtime processes remain separate.'}
    results['resource_provenance'] = {'inputs_sha256': sources,
                                     'duration_histogram': [{'seconds': duration, 'unique_jobs': count} for duration, count in sorted(histogram.items())],
                                     'source_sha256': digest(__file__)}
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['results', 'prepared', 'models', 'frontend', 'output']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--resource-receipt', type=Path, action='append', default=[])
    args = parser.parse_args()
    sources = {}
    results, prepared = read(args.results, sources), read(args.prepared, sources)
    entries, frontend = read(args.models, sources), read(args.frontend, sources)
    assembled = assemble(results, prepared, entries, frontend, sources, args.resource_receipt, prepared_sha256=digest(args.prepared))
    if any(digest(path) != value for path, value in sources.items()):
        raise ValueError('Resource inputs changed while assembling the report.')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(args.output.suffix + '.partial')
    temporary.write_text(json.dumps(assembled, allow_nan=False, separators=(',', ':')) + '\n')
    temporary.replace(args.output)


if __name__ == '__main__':
    main()
