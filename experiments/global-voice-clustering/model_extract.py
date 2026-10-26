#!/usr/bin/env python3
"""Prepare complete speech contexts and extract resumable model embeddings locally."""
import argparse
from collections import defaultdict
import hashlib
import importlib
import json
import math
from pathlib import Path
import subprocess
import time

import numpy as np

RATE = 16000


def stable(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False)


def digest(path):
    with Path(path).open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()


def atomic_json(path, value):
    temporary = path.with_suffix(path.suffix + '.partial')
    temporary.write_text(stable(value))
    temporary.replace(path)


def unchanged_receipt(path, value):
    if path.exists() and json.loads(path.read_text()) != value:
        raise ValueError('Inputs or configuration changed; use a new output directory.')
    atomic_json(path, value)


def frames(spans, count):
    bounds = []
    for span in spans:
        start, end = float(span['start']), float(span['end'])
        if not math.isfinite(start) or not math.isfinite(end) or not 0 <= start < end:
            raise ValueError('Invalid embedding support bounds.')
        left, right = math.floor(start * RATE + .5), math.floor(end * RATE + .5)
        if not 0 <= left < right <= count or (bounds and left < bounds[-1][1]):
            raise ValueError('Embedding support exceeds recording or overlaps itself.')
        bounds.append([left, right])
    if not bounds:
        raise ValueError('Embedding support is empty.')
    return bounds


def prepare(input_path, output):
    input_path, output = Path(input_path).resolve(), Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    manifest_path = input_path.parent / 'full-speech-manifest.json'
    input_hash, manifest_hash = digest(input_path), digest(manifest_path)
    document = json.loads(input_path.read_text())
    manifest = json.loads(manifest_path.read_text())
    if not manifest['summary']['complete']:
        raise ValueError('Full-speech manifest is incomplete.')
    version = subprocess.run(['ffmpeg', '-version'], capture_output=True, text=True, check=True).stdout.splitlines()[0]
    receipt = dict(input_path=str(input_path), input_sha256=input_hash,
                   manifest_sha256=manifest_hash, ffmpeg_version=version,
                   source_sha256=digest(Path(__file__)), sample_rate=RATE, format='f32le_mono')
    unchanged_receipt(output / 'prepare-provenance.json', receipt)
    meetings = {row['id']: row for row in document['meetings']}
    tracks = {}
    for row in manifest['recordings']:
        if row['status'] != 'complete':
            raise ValueError('Manifest contains an incomplete recording.')
        source = input_path.parent / 'library/meetings' / meetings[row['meeting_id']]['folder'] / row['audio_file']
        if source.is_symlink():
            raise ValueError('Source audio must be an independent file.')
        source = source.resolve()
        source.relative_to((input_path.parent / 'library/meetings').resolve())
        key = hashlib.sha256(stable([row['meeting_id'], row['audio_file']]).encode()).hexdigest()
        pcm = output / (key + '.f32')
        checkpoint = output / (key + '.json')
        if digest(source) != row['audio_sha256']:
            raise ValueError('Source audio differs from the VAD manifest.')
        track = dict(source=str(source), source_sha256=row['audio_sha256'],
                     decoded_samples=row['decoded_samples'], pcm_path=str(pcm))
        if checkpoint.exists():
            previous = json.loads(checkpoint.read_text())
            if any(previous.get(field) != value for field, value in track.items()):
                raise ValueError('Decoded audio checkpoint belongs to different inputs.')
            if not pcm.exists() or digest(pcm) != previous['pcm_sha256']:
                raise ValueError('Decoded audio checkpoint changed.')
            track = previous
        else:
            temporary = pcm.with_suffix('.partial')
            command = ['ffmpeg', '-v', 'error', '-nostdin', '-y', '-i', str(source), '-map', '0:a:0',
                       '-ac', '1', '-ar', str(RATE), '-f', 'f32le', str(temporary)]
            subprocess.run(command, check=True)
            if temporary.stat().st_size != row['decoded_samples'] * 4:
                raise ValueError('Decoded frame count differs from the VAD manifest.')
            audio = np.memmap(temporary, dtype='<f4', mode='r')
            if not np.isfinite(audio).all():
                raise ValueError('Decoded audio contains nonfinite samples.')
            del audio
            if digest(source) != row['audio_sha256']:
                raise ValueError('Source changed during decoding.')
            temporary.replace(pcm)
            track.update(pcm_sha256=digest(pcm), decode_command=command)
            atomic_json(checkpoint, track)
        if pcm.stat().st_size != row['decoded_samples'] * 4:
            raise ValueError('Decoded audio frame count changed.')
        tracks[str(source)] = track
        print(stable(dict(stage='prepare', recordings=len(tracks), total=len(manifest['recordings']))), flush=True)
    jobs, aliases = {}, []
    seen_ids = set()
    for sample in document['samples']:
        if not sample.get('eligible'):
            raise ValueError('The requested complete extraction includes an ineligible sample.')
        if sample['id'] in seen_ids:
            raise ValueError('Sample identifiers must be unique.')
        seen_ids.add(sample['id'])
        source = str((input_path.parent / sample['audio_path']).resolve())
        track = tracks[source]
        if sample.get('audio_revision') != track['source_sha256']:
            raise ValueError('Sample audio revision differs from the VAD manifest.')
        bounds = frames(sample['embedding_spans'], track['decoded_samples'])
        key = sample['density_key']
        job = dict(key=key, source=source, bounds=bounds, sample_count=sum(b-a for a,b in bounds))
        if key in jobs and jobs[key] != job:
            raise ValueError('One physical density key has conflicting audio support.')
        jobs[key] = job
        aliases.append(dict(id=sample['id'], key=key, embedding_spans=sample['embedding_spans'],
                            support_spans=sample['support_spans']))
    if len(document['examples']) != len(aliases):
        raise ValueError('Sample and example coverage differs.')
    if digest(input_path) != input_hash or digest(manifest_path) != manifest_hash:
        raise ValueError('Preparation input changed.')
    verify_tracks(tracks)
    prepared = dict(provenance=receipt, tracks=tracks, jobs=sorted(jobs.values(), key=lambda row: row['key']), aliases=aliases)
    atomic_json(output / 'prepared.json', prepared)
    return prepared


def verify_tracks(tracks):
    for track in tracks.values():
        if digest(track['source']) != track['source_sha256'] or digest(track['pcm_path']) != track['pcm_sha256']:
            raise ValueError('Source or decoded audio changed.')


def verify_input(provenance):
    original = Path(provenance['input_path'])
    if digest(original) != provenance['input_sha256']:
        raise ValueError('Original full-speech input changed.')
    if ('manifest_sha256' in provenance
            and digest(original.parent / 'full-speech-manifest.json') != provenance['manifest_sha256']):
        raise ValueError('Original full-speech manifest changed.')


def normalize(values, count, dimension=None):
    values = np.asarray(values, dtype=np.float32)
    if values.ndim != 2 or values.shape[0] != count or values.shape[1] < 1:
        raise ValueError('Adapter returned an unexpected embedding shape.')
    if dimension is not None and values.shape[1] != dimension:
        raise ValueError('Adapter embedding dimension changed.')
    norms = np.linalg.norm(values.astype(np.float64), axis=1, keepdims=True)
    if not np.isfinite(values).all() or not np.isfinite(norms).all() or (norms <= 0).any():
        raise ValueError('Adapter returned an invalid embedding.')
    return (values / norms).astype(np.float32)


def atomic_npz(path, **values):
    temporary = path.with_suffix(path.suffix + '.partial')
    with temporary.open('wb') as handle:
        np.savez_compressed(handle, **values)
    temporary.replace(path)


def synchronize(adapter):
    if str(getattr(adapter, 'device', 'cpu')).startswith('mps'):
        import torch
        torch.mps.synchronize()


def extract(prepared_path, output, config_path, batch_size=8, limit=0):
    if batch_size < 1 or limit < 0:
        raise ValueError('Batch size must be positive and limit must be nonnegative.')
    prepared_path, output, config_path = Path(prepared_path).resolve(), Path(output).resolve(), Path(config_path).resolve()
    output.mkdir(parents=True, exist_ok=True)
    if limit and (output / 'embeddings.npz').exists():
        raise ValueError('Use a separate benchmark directory when a complete output exists.')
    prepared_hash = digest(prepared_path)
    prepared = json.loads(prepared_path.read_text())
    verify_tracks(prepared['tracks'])
    provenance = prepared['provenance']
    verify_input(provenance)
    config = json.loads(config_path.read_text())
    module = importlib.import_module(config['module'])
    code_hash = digest(Path(module.__file__))
    external_code = config.get('kwargs', {}).get('code_dir')
    source_hashes = ({str(path.relative_to(external_code)): digest(path)
                      for path in sorted(Path(external_code).rglob('*.py'))} if external_code else {})
    started = time.monotonic()
    adapter = module.load_model(**config['kwargs'])
    synchronize(adapter)
    load_seconds = time.monotonic() - started
    metadata = adapter.metadata
    receipt = dict(schema_version=1, prepared_sha256=prepared_hash, config=config,
                   adapter_sha256=code_hash, external_source_sha256=source_hashes,
                   extraction_source_sha256=digest(Path(__file__)), model_metadata=metadata,
                   batch_size=batch_size, numpy_version=np.__version__)
    unchanged_receipt(output / 'extraction-provenance.json', receipt)
    receipt_hash = hashlib.sha256(stable(receipt).encode()).hexdigest()
    groups = defaultdict(list)
    selected_jobs = prepared['jobs'][:limit] if limit else prepared['jobs']
    for job in selected_jobs:
        groups[job['sample_count']].append(job)
    batches = [group[start:start+batch_size] for _, group in sorted(groups.items()) for start in range(0,len(group),batch_size)]
    checkpoint_root = output / 'checkpoints'
    checkpoint_root.mkdir(exist_ok=True)
    mmap = {}
    embeddings = {}
    processed = 0
    inference_seconds = 0.
    dimension = metadata.get('embedding_dimension')
    for batch in batches:
        keys = [job['key'] for job in batch]
        identity = hashlib.sha256(stable(keys).encode()).hexdigest()
        checkpoint = checkpoint_root / (identity + '.npz')
        record_path = checkpoint.with_suffix('.json')
        if record_path.exists():
            record = json.loads(record_path.read_text())
            if record['provenance_sha256'] != receipt_hash or record['keys'] != keys:
                raise ValueError('Embedding checkpoint belongs to different inputs.')
            if digest(checkpoint) != record['checkpoint_sha256']:
                raise ValueError('Embedding checkpoint changed.')
            with np.load(checkpoint, allow_pickle=False) as cached:
                if cached['keys'].tolist() != keys:
                    raise ValueError('Embedding checkpoint identifiers changed.')
                vectors = normalize(cached['embeddings'], len(batch), dimension)
        else:
            waveforms = []
            for job in batch:
                source = job['source']
                if source not in mmap:
                    mmap[source] = np.memmap(prepared['tracks'][source]['pcm_path'], dtype='<f4', mode='r')
                waveforms.append(np.concatenate([mmap[source][left:right] for left,right in job['bounds']]))
            synchronize(adapter)
            tick = time.monotonic()
            try:
                vectors = normalize(adapter.embed_batch(np.stack(waveforms)), len(batch), dimension)
                synchronize(adapter)
            except Exception as error:
                atomic_json(output / 'last-failure.json', dict(keys=keys, error=f'{type(error).__name__}: {error}'))
                raise
            elapsed = time.monotonic() - tick
            inference_seconds += elapsed
            atomic_npz(checkpoint, keys=np.asarray(keys), embeddings=vectors)
            atomic_json(record_path, dict(provenance_sha256=receipt_hash, keys=keys,
                                         checkpoint_sha256=digest(checkpoint), inference_seconds=elapsed))
        dimension = vectors.shape[1]
        embeddings.update(zip(keys, vectors))
        processed += len(batch)
        print(stable(dict(stage='extract', unique_jobs=processed, total=len(prepared['jobs']))), flush=True)
    complete = len(embeddings) == len(prepared['jobs']) and not limit
    if digest(prepared_path) != prepared_hash or json.loads(config_path.read_text()) != config:
        raise ValueError('Extraction inputs changed during inference.')
    verify_input(provenance)
    if digest(Path(module.__file__)) != code_hash:
        raise ValueError('Adapter changed during inference.')
    if external_code and source_hashes != {str(path.relative_to(external_code)): digest(path)
                                          for path in sorted(Path(external_code).rglob('*.py'))}:
        raise ValueError('Model source changed during inference.')
    checkpoint_name = metadata.get('checkpoint')
    model_dir = config['kwargs'].get('model_dir')
    if checkpoint_name and model_dir and digest(Path(model_dir) / checkpoint_name) != metadata['checkpoint_sha256']:
        raise ValueError('Model checkpoint changed during inference.')
    verify_tracks(prepared['tracks'])
    summary = dict(complete=complete, benchmark=bool(limit), unique_jobs=len(embeddings),
                   expected_unique_jobs=len(prepared['jobs']), expected_rows=len(prepared['aliases']),
                   model_metadata=metadata, load_seconds=load_seconds, new_inference_seconds=inference_seconds,
                   resources='See the external measure.py receipt.')
    if complete:
        aliases = prepared['aliases']
        atomic_npz(output / 'embeddings.npz', ids=np.asarray([row['id'] for row in aliases]),
                   embeddings=np.stack([embeddings[row['key']] for row in aliases]),
                   model_id=np.asarray(metadata.get('model_id', config['module'])))
    atomic_json(output / ('benchmark-summary.json' if limit else 'summary.json'), summary)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    prep = sub.add_parser('prepare')
    prep.add_argument('--input', type=Path, required=True)
    prep.add_argument('--output', type=Path, required=True)
    infer = sub.add_parser('extract')
    infer.add_argument('--prepared', type=Path, required=True)
    infer.add_argument('--output', type=Path, required=True)
    infer.add_argument('--adapter-config', type=Path, required=True)
    infer.add_argument('--batch-size', type=int, default=8)
    infer.add_argument('--limit', type=int, default=0, help='Benchmark unique jobs; never publishes a complete NPZ.')
    args = parser.parse_args()
    if args.command == 'prepare':
        prepare(args.input, args.output)
    else:
        extract(args.prepared, args.output, args.adapter_config, args.batch_size, args.limit)


if __name__ == '__main__':
    main()
