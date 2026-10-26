#!/usr/bin/env python3
"""Convert feature backbones and measure Core ML in a separate, Torch-free process.

Use convert with Torch 2.7 (Core ML Tools 9.0 tested pairing), torchaudio 2.7,
coremltools, numpy, and the adapter dependencies. Use predict with only
coremltools/numpy/psutil. Wrap each command in measure.py for process receipts.
Official APIs: https://apple.github.io/coremltools/docs-guides/source/convert-pytorch-workflow.html
https://apple.github.io/coremltools/docs-guides/source/model-prediction.html
"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib
import importlib.metadata
import json
from pathlib import Path
import platform
import re
import statistics
import sys
import time
import traceback


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + '.partial')
    temporary.write_text(json.dumps(value, indent=2, allow_nan=False) + '\n')
    temporary.replace(path)


def package_bytes(path):
    return sum(item.stat().st_size for item in path.rglob('*') if item.is_file())


def parity(expected, actual):
    import numpy as np
    reference = np.asarray(expected, dtype=np.float64).reshape(-1)
    candidate = np.asarray(actual, dtype=np.float64).reshape(-1)
    if reference.shape != candidate.shape or not np.isfinite(candidate).all() or not np.isfinite(reference).all():
        raise ValueError('Output shape or finite-value check failed.')
    denominator = np.linalg.norm(reference) * np.linalg.norm(candidate)
    if not denominator:
        raise ValueError('Embedding has zero magnitude.')
    return {'cosine': float(np.dot(reference, candidate) / denominator),
            'relative_l2': float(np.linalg.norm(reference - candidate) / np.linalg.norm(reference)),
            'max_absolute': float(np.max(np.abs(reference - candidate)))}


def synthetic_audio(seconds, seed=20261025):
    import numpy as np
    size = round(seconds * 16000)
    generator = np.random.default_rng(seed)
    position = np.arange(size, dtype=np.float64) / 16000
    envelope = .25 + .75 * np.sin(2 * np.pi * 2.3 * position) ** 2
    signal = sum(np.sin(2 * np.pi * frequency * position) / (index + 1)
                 for index, frequency in enumerate([137, 274, 411, 548]))
    return (envelope * .12 * signal + generator.normal(0, .015, size)).astype(np.float32)


def convert(args, result):
    import numpy as np
    import torch
    import coremltools as ct
    torch.set_num_threads(args.threads)
    adapter = importlib.import_module(args.adapter).load_model(
        args.model_id, args.model_dir, args.code_dir, device='cpu')
    print('Loaded adapter.', flush=True)
    module = adapter.embedding_model.eval()
    result['adapter_metadata'] = adapter.metadata
    count = sum(parameter.numel() for parameter in module.parameters())
    result['weight_storage_estimate'] = {
        'parameters': count, 'float16_parameter_bytes': 2 * count,
        'float32_parameter_bytes': 4 * count,
        'scope': 'Parameter payload only. Excludes buffers, package metadata, compiler artifacts, activations, frontend, and runtime memory.'}
    result['export_adjustments'] = []
    result['cases'] = []
    cases = [(f'synthetic-{seconds:g}s', synthetic_audio(seconds)) for seconds in args.seconds]
    if args.audio_npz:
        # Private, mono 16 kHz arrays; keys become local receipt labels only.
        with np.load(args.audio_npz, allow_pickle=False) as archive:
            cases.extend((key, archive[key].astype(np.float32)) for key in archive.files)
    packages = {}
    for index, (label, audio) in enumerate(cases):
        case = {'label': label, 'sample_count': len(audio), 'status': 'running'}
        result['cases'].append(case)
        print(f'Preparing {label}.', flush=True)
        try:
            if audio.ndim != 1 or len(audio) < 512 or not np.isfinite(audio).all():
                raise ValueError('Input must be finite mono PCM with at least 512 samples.')
            features = adapter.features(torch.from_numpy(audio.copy()).unsqueeze(0)).detach().clone()
            with torch.inference_mode():
                expected = module(features).detach().cpu().numpy()
            shape = tuple(features.shape)
            case['feature_shape'] = list(shape)
            if shape not in packages:
                # Core ML Tools 9 requires float clip bounds for float tensors.
                # Upstream ERes2NetV2 uses integer 0/20 bounds; preserve their
                # values while making the TorchScript scalar types explicit.
                adjusted = 0
                for child in module.modules():
                    if isinstance(child, torch.nn.Hardtanh) and (isinstance(child.min_val, int) or isinstance(child.max_val, int)):
                        child.min_val = float(child.min_val)
                        child.max_val = float(child.max_val)
                        adjusted += 1
                if adjusted:
                    result['export_adjustments'].append({'kind': 'float_hardtanh_bounds', 'module_count': adjusted, 'reason': 'Core ML Tools 9 clip scalar type compatibility; bound values unchanged.'})
                # Fixed shapes keep trace specialization explicit and reproducible.
                print(f'Tracing feature shape {shape}.', flush=True)
                traced = torch.jit.trace(module, features, check_trace=True)
                with torch.inference_mode():
                    traced_output = traced(features).cpu().numpy()
                    case['torchscript_parity'] = parity(expected, traced_output)
                    np.testing.assert_allclose(expected, traced_output, rtol=1e-5, atol=1e-6)
                started = time.perf_counter()
                print(f'Converting feature shape {shape}.', flush=True)
                model = ct.convert(traced, source='pytorch', convert_to='mlprogram',
                                   inputs=[ct.TensorType(name='features', shape=shape, dtype=np.float32)],
                                   outputs=[ct.TensorType(name='embedding', dtype=np.float32)],
                                   minimum_deployment_target=ct.target.macOS15,
                                   compute_precision=getattr(ct.precision, args.precision), skip_model_load=True)
                package = args.output / f'backbone-{len(packages)}.mlpackage'
                model.save(str(package))
                case['conversion_seconds'] = time.perf_counter() - started
                packages[shape] = package.name
                case['package_bytes'] = package_bytes(package)
            fixture = args.output / f'case-{index}.npz'
            np.savez(fixture, features=features.cpu().numpy(), expected=expected)
            case.update(status='converted', package=packages[shape], fixture=fixture.name,
                        fixture_sha256=hashlib.sha256(fixture.read_bytes()).hexdigest())
        except Exception as error:
            case.update(status='failed', error_type=type(error).__name__, error=str(error), traceback=traceback.format_exc())
        write_json(args.output / 'conversion.json', result)
    if any(case['status'] == 'failed' for case in result['cases']):
        raise RuntimeError('One or more conversion cases failed. See conversion.json.')


def prepare_fixtures(args, result):
    """Prepare native references for existing packages without reconversion."""
    import numpy as np
    import torch
    torch.set_num_threads(args.threads)
    source_receipt = args.output / 'conversion.json'
    conversion = json.loads(source_receipt.read_text())
    if conversion.get('status') != 'complete':
        raise ValueError('Existing conversion must be complete.')
    adapter = importlib.import_module(args.adapter).load_model(
        args.model_id, args.model_dir, args.code_dir, device='cpu')
    for field in ['model_id', 'checkpoint_sha256']:
        if adapter.metadata[field] != conversion['adapter_metadata'][field]:
            raise ValueError('Adapter checkpoint differs from the converted model.')
    packages = {tuple(case['feature_shape']): case['package'] for case in conversion['cases']}
    result.update(adapter_metadata=adapter.metadata, cases=[],
                  audio_sha256=hashlib.sha256(args.audio_npz.read_bytes()).hexdigest(),
                  source_conversion_sha256=hashlib.sha256(source_receipt.read_bytes()).hexdigest())
    with np.load(args.audio_npz, allow_pickle=False) as archive:
        for index, label in enumerate(archive.files):
            audio = np.asarray(archive[label], dtype=np.float32)
            if audio.ndim != 1 or len(audio) < 512 or not np.isfinite(audio).all():
                raise ValueError('Private input must be finite mono 16 kHz PCM.')
            features = adapter.features(torch.from_numpy(audio.copy()).unsqueeze(0))
            shape = tuple(features.shape)
            if shape not in packages:
                raise ValueError(f'No existing package accepts feature shape {shape}.')
            with torch.inference_mode():
                expected = adapter.embedding_model(features).cpu().numpy()
            fixture = args.output / f'fixture-{args.run_label}-{index}.npz'
            if fixture.exists():
                raise ValueError('Fixture already exists; choose a new run-label.')
            np.savez(fixture, features=features.cpu().numpy(), expected=expected)
            result['cases'].append(dict(label=label, sample_count=len(audio), status='prepared',
                                        feature_shape=list(shape), package=packages[shape], fixture=fixture.name,
                                        fixture_sha256=hashlib.sha256(fixture.read_bytes()).hexdigest()))
            write_json(args.receipt, result)
    if hashlib.sha256(args.audio_npz.read_bytes()).hexdigest() != result['audio_sha256']:
        raise ValueError('Private input windows changed during fixture preparation.')
    if hashlib.sha256(source_receipt.read_bytes()).hexdigest() != result['source_conversion_sha256']:
        raise ValueError('Conversion receipt changed during fixture preparation.')


def predict(args, result):
    import numpy as np
    import psutil
    import coremltools as ct
    if 'torch' in sys.modules:
        raise RuntimeError('Torch is loaded; use an environment without Torch for runtime measurement.')
    manifest = args.fixtures_manifest or args.output / 'conversion.json'
    conversion = json.loads(manifest.read_text())
    result['fixture_manifest_sha256'] = hashlib.sha256(manifest.read_bytes()).hexdigest()
    if conversion.get('status') != 'complete':
        raise ValueError('Conversion receipt must be complete before runtime measurement.')
    process = psutil.Process()
    result.update(compute_units=args.compute_units, repeats=args.repeats, cases=[],
                  rss_scope='This Python process only. Includes Python, NumPy, Core ML Tools and model/runtime allocations. Device allocations and other processes are excluded.',
                  baseline_rss_bytes=process.memory_info().rss)
    units = getattr(ct.ComputeUnit, args.compute_units)
    selected = [case for case in conversion['cases'] if not args.case_label or case['label'] == args.case_label]
    if not selected:
        raise ValueError('No conversion fixture matches case-label.')
    # Runtime caches can survive model release. Use case-label in fresh processes
    # when measuring a single deployed shape rather than a sequence of packages.
    for package in sorted({case['package'] for case in selected}):
        started = time.perf_counter()
        model = ct.models.MLModel(str(args.output / package), compute_units=units)
        load_seconds = time.perf_counter() - started
        loaded_rss = process.memory_info().rss
        for case in (item for item in selected if item['package'] == package):
            fixture_path = args.output / case['fixture']
            if hashlib.sha256(fixture_path.read_bytes()).hexdigest() != case['fixture_sha256']:
                raise ValueError('Fixture checksum differs from the conversion receipt.')
            with np.load(fixture_path, allow_pickle=False) as fixture:
                features, expected = fixture['features'], fixture['expected']
            start = time.perf_counter()
            actual = model.predict({'features': features})['embedding']
            cold = time.perf_counter() - start
            metrics = parity(expected, actual)
            timings = []
            for _ in range(args.repeats):
                start = time.perf_counter()
                model.predict({'features': features})
                timings.append(time.perf_counter() - start)
            result['cases'].append({'label': case['label'], 'package': package,
                                    'load_seconds': load_seconds, 'first_prediction_seconds': cold,
                                    'warm_prediction_seconds': timings,
                                    'warm_median_seconds': statistics.median(timings),
                                    'loaded_rss_bytes': loaded_rss,
                                    'after_predictions_rss_bytes': process.memory_info().rss,
                                    'parity': metrics,
                                    'parity_pass': metrics['cosine'] >= args.minimum_cosine and metrics['relative_l2'] <= args.maximum_relative_l2})
            write_json(args.receipt, result)
        del model
    if not all(case['parity_pass'] for case in result['cases']):
        raise RuntimeError('Core ML numerical parity threshold failed.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', choices=['convert', 'predict', 'fixtures'])
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--adapter')
    parser.add_argument('--model-id')
    parser.add_argument('--model-dir')
    parser.add_argument('--code-dir')
    parser.add_argument('--audio-npz', type=Path)
    parser.add_argument('--fixtures-manifest', type=Path)
    parser.add_argument('--run-label', default='')
    parser.add_argument('--case-label')
    parser.add_argument('--seconds', nargs='+', type=float, default=[2, 3, 5])
    parser.add_argument('--threads', type=int, default=2)
    parser.add_argument('--precision', choices=['FLOAT16', 'FLOAT32'], default='FLOAT16')
    parser.add_argument('--repeats', type=int, default=10)
    parser.add_argument('--compute-units', choices=['ALL', 'CPU_ONLY', 'CPU_AND_NE', 'CPU_AND_GPU'], default='ALL')
    parser.add_argument('--minimum-cosine', type=float, default=.999)
    parser.add_argument('--maximum-relative-l2', type=float, default=.03)
    args = parser.parse_args()
    if args.repeats < 1 or args.threads < 1 or any(not 0 < seconds <= 60 for seconds in args.seconds):
        parser.error('Use positive repeats, threads, and durations up to 60 seconds.')
    if args.stage in ('convert', 'fixtures') and not all([args.adapter, args.model_id, args.model_dir, args.code_dir]):
        parser.error('Conversion requires adapter, model-id, model-dir, and code-dir.')
    if args.stage == 'fixtures' and (not args.audio_npz or not args.run_label):
        parser.error('Fixture preparation requires audio-npz and run-label.')
    if args.run_label and not re.fullmatch(r'[a-z0-9-]+', args.run_label):
        parser.error('Use lowercase letters, numbers, and hyphens in run-label.')
    args.output.mkdir(parents=True, exist_ok=True)
    suffix = '-' + args.run_label if args.run_label else ''
    receipt_name = {'convert': 'conversion.json', 'fixtures': f'fixtures{suffix}.json',
                    'predict': f'prediction-{args.compute_units}{suffix}.json'}[args.stage]
    receipt = args.output / receipt_name
    args.receipt = receipt
    if receipt.exists():
        parser.error('Receipt exists. Use a fresh output directory, run-label, or compute-unit setting.')
    result = {'schema_version': 1, 'stage': args.stage, 'status': 'running',
              'started_at': datetime.now(timezone.utc).isoformat(), 'platform': platform.platform(),
              'run_label': args.run_label, 'case_label': args.case_label,
              'conversion_precision': args.precision if args.stage == 'convert' else None,
              'harness_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              'scope': 'Fixed-shape feature-to-raw-embedding backbone. Excludes waveform frontend and L2 normalization. Numerical parity is separate from speaker accuracy.',
              'versions': {name: importlib.metadata.version(name) for name in ['numpy', 'coremltools']}}
    started = time.perf_counter()
    try:
        if args.stage == 'convert':
            result['versions']['torch'] = importlib.metadata.version('torch')
            convert(args, result)
        elif args.stage == 'fixtures':
            result['versions']['torch'] = importlib.metadata.version('torch')
            prepare_fixtures(args, result)
        else:
            predict(args, result)
        result['status'] = 'complete'
    except Exception as error:
        result.update(status='failed', error_type=type(error).__name__, error=str(error), traceback=traceback.format_exc())
        raise
    finally:
        result['elapsed_seconds'] = time.perf_counter() - started
        write_json(receipt, result)


if __name__ == '__main__':
    main()
