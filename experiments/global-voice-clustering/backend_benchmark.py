#!/usr/bin/env python3
"""Measure CPU frontends or verify CPU/MPS parity on authorized local windows.

Run model jobs sequentially with measure.py. Inputs and receipts belong in tmp/.
MPS API: https://docs.pytorch.org/docs/stable/mps.html
"""
import argparse
from collections import defaultdict
from datetime import datetime, timezone
import hashlib
import importlib
import json
import os
from pathlib import Path
import statistics
import time
import traceback

import numpy as np

from coreml_benchmark import parity, write_json


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def passes(metrics, minimum_cosine, maximum_relative_l2):
    return metrics['cosine'] >= minimum_cosine and metrics['relative_l2'] <= maximum_relative_l2


def normalized(vector):
    value = np.asarray(vector, dtype=np.float64)
    norm = np.linalg.norm(value, axis=-1, keepdims=True)
    if not np.isfinite(value).all() or not np.isfinite(norm).all() or (norm <= 0).any():
        raise ValueError('Invalid reference embedding.')
    return (value / norm).astype(np.float32)


def frontend(adapter, windows, args, result):
    dimension = adapter.metadata['embedding_dimension']
    # Measure only normalization work, using generic values with the model's size.
    vector = np.linspace(1, 2, dimension, dtype=np.float32)
    normalization = []
    for _ in range(args.repeats):
        start = time.perf_counter()
        for _ in range(1000):
            normalized(vector)
        normalization.append((time.perf_counter() - start) / 1000)
    result['normalization_median_seconds'] = statistics.median(normalization)
    result['normalization_scope'] = 'NumPy float64 L2 norm and float32 output, synthetic vector of the actual embedding dimension.'
    for label, wave in windows:
        tensor = args.torch.from_numpy(wave.copy()).unsqueeze(0)
        start = time.perf_counter()
        features = adapter.features(tensor)
        first = time.perf_counter() - start
        if features.device.type != 'cpu':
            raise ValueError('Frontend must execute on CPU.')
        times = []
        for _ in range(args.repeats):
            start = time.perf_counter()
            adapter.features(tensor)
            times.append(time.perf_counter() - start)
        result['cases'].append(dict(label=label, sample_count=len(wave), seconds=len(wave)/16000,
                                    feature_shape=list(features.shape), first_seconds=first,
                                    frontend_seconds=times, frontend_median_seconds=statistics.median(times)))


def backend_parity(cpu, mps, windows, args, result):
    torch = args.torch
    for field in ['checkpoint_sha256', 'embedding_dimension']:
        if cpu.metadata[field] != mps.metadata[field]:
            raise ValueError('CPU and MPS models differ.')
    for label, wave in windows:
        tensor = torch.from_numpy(wave.copy()).unsqueeze(0)
        features = cpu.features(tensor)
        other_features = mps.features(tensor)
        if features.device.type != 'cpu' or other_features.device.type != 'cpu':
            raise ValueError('Both frontend paths must remain on CPU.')
        torch.testing.assert_close(features, other_features, rtol=0, atol=0)
        with torch.inference_mode():
            expected = cpu.embedding_model(features).cpu().numpy()
            actual = mps.embedding_model(features.to('mps'))
            torch.mps.synchronize()
            actual = actual.cpu().numpy()
        metrics = parity(expected, actual)
        result['cases'].append(dict(label=label, sample_count=len(wave), raw_backbone_parity=metrics,
                                    pass_parity=passes(metrics, args.minimum_cosine, args.maximum_relative_l2)))
    groups = defaultdict(list)
    for label, wave in windows:
        groups[len(wave)].append((label, wave))
    result['batches'] = []
    for count, group in sorted(groups.items()):
        waves = np.stack([wave for _, wave in group])
        cpu_batch = cpu.embed_batch(waves)
        mps_batch = mps.embed_batch(waves)
        torch.mps.synchronize()
        for index, (label, wave) in enumerate(group):
            cpu_single, mps_single = cpu.embed(wave), mps.embed(wave)
            torch.mps.synchronize()
            metrics = {'cpu_vs_mps_batch': parity(cpu_batch[index], mps_batch[index]),
                       'cpu_batch_vs_single': parity(cpu_single, cpu_batch[index]),
                       'mps_batch_vs_single': parity(mps_single, mps_batch[index])}
            result['batches'].append(dict(label=label, sample_count=count, batch_size=len(group),
                                          metrics=metrics, pass_parity=all(passes(metric, args.minimum_cosine, args.maximum_relative_l2) for metric in metrics.values())))
    result['mps_memory_bytes_after'] = dict(tensors=torch.mps.current_allocated_memory(),
                                          driver=torch.mps.driver_allocated_memory())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', choices=['frontend', 'parity'])
    parser.add_argument('--configs', type=Path, nargs='+', required=True)
    parser.add_argument('--audio-npz', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--threads', type=int, default=4)
    parser.add_argument('--repeats', type=int, default=10)
    parser.add_argument('--minimum-cosine', type=float, default=.99999)
    parser.add_argument('--maximum-relative-l2', type=float, default=.005)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Receipt exists. Choose a new output path.')
    if args.threads < 1 or args.repeats < 1:
        parser.error('Use positive threads and repeats.')
    # Set before importing Torch; unsupported MPS operations must fail explicitly.
    if args.stage == 'parity':
        os.environ['PYTORCH_ENABLE_MPS_FALLBACK'] = '0'
    import torch
    import torchaudio
    args.torch = torch
    torch.set_num_threads(args.threads)
    result = dict(schema_version=1, stage=args.stage, status='running',
                  started_at=datetime.now(timezone.utc).isoformat(), threads=args.threads,
                  torch_version=str(torch.__version__), torchaudio_version=str(torchaudio.__version__),
                  numpy_version=np.__version__, audio_sha256=digest(args.audio_npz),
                  harness_sha256=digest(__file__), models=[],
                  scope='CPU waveform frontend measured separately from backbone. Parity compares identical float32 weights, CPU frontends, raw backbones and normalized batch/single embeddings; speaker accuracy is unmeasured.')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    try:
        if args.stage == 'parity' and not torch.backends.mps.is_available():
            raise RuntimeError('MPS is unavailable. Run outside the sandbox on a supported Mac.')
        with np.load(args.audio_npz, allow_pickle=False) as archive:
            windows = [(name, np.asarray(archive[name], dtype=np.float32)) for name in archive.files]
        if not windows or any(wave.ndim != 1 or len(wave) < 512 or not np.isfinite(wave).all() for _, wave in windows):
            raise ValueError('Provide finite mono 16 kHz windows with at least 512 samples each.')
        for config_path in args.configs:
            model_result = dict(config_sha256=digest(config_path), status='running', cases=[])
            result['models'].append(model_result)
            try:
                config = json.loads(config_path.read_text())
                module = importlib.import_module(config['module'])
                model_result['adapter_sha256'] = digest(module.__file__)
                kwargs = dict(config['kwargs'], device='cpu')
                cpu = module.load_model(**kwargs)
                model_result.update(model_id=cpu.metadata['model_id'], cpu_metadata=cpu.metadata,
                                    dtype=str(next(cpu.embedding_model.parameters()).dtype),
                                    cpu_backend=next(cpu.embedding_model.parameters()).device.type)
                if args.stage == 'frontend':
                    frontend(cpu, windows, args, model_result)
                else:
                    mps = module.load_model(**dict(config['kwargs'], device='mps'))
                    model_result['mps_metadata'] = mps.metadata
                    model_result['mps_backend'] = next(mps.embedding_model.parameters()).device.type
                    backend_parity(cpu, mps, windows, args, model_result)
                    del mps
                    torch.mps.empty_cache()
                del cpu
                model_result['status'] = 'complete'
                if args.stage == 'parity' and not all(case['pass_parity'] for case in model_result['cases'] + model_result['batches']):
                    raise ValueError('CPU/MPS numerical parity threshold failed.')
            except Exception as error:
                model_result.update(status='failed', error=str(error), traceback=traceback.format_exc())
            write_json(args.output, result)
        if digest(args.audio_npz) != result['audio_sha256']:
            raise ValueError('Input windows changed during measurement.')
        result['status'] = 'complete' if all(model['status'] == 'complete' for model in result['models']) else 'failed'
    except Exception as error:
        result.update(status='failed', error=str(error), traceback=traceback.format_exc())
    finally:
        write_json(args.output, result)
    return result['status'] != 'complete'


if __name__ == '__main__':
    raise SystemExit(main())
