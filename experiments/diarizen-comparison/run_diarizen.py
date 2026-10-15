"""Offline-only official DiariZen inference; download artifacts separately."""
import argparse
import json
import os
from pathlib import Path
import time
import uuid

os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'
p = argparse.ArgumentParser()
p.add_argument('--inputs', type=Path, required=True)
p.add_argument('--model', type=Path, required=True)
p.add_argument('--embedding', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--threads', type=int, default=4)
p.add_argument('--batch-size', type=int, default=4)
a = p.parse_args()
import torch
from diarizen.pipelines.inference import DiariZenPipeline
import toml

torch.set_num_threads(a.threads)
torch.set_num_interop_threads(1)
if torch.cuda.is_available():
    raise RuntimeError('This comparison specifies CPU; upstream auto-selects CUDA on this host.')
a.output.mkdir(parents=True, exist_ok=True)
start = time.monotonic()
config = toml.load(a.model / "config.toml")
config["inference"]["args"]["batch_size"] = a.batch_size
pipeline = DiariZenPipeline(diarizen_hub=a.model, embedding_model=str(a.embedding), config_parse=config)
load_seconds = time.monotonic() - start
manifest = json.loads(a.inputs.read_text())
turns, timings = [], []
for track in manifest['tracks']:
    print('Starting', track['track'], 'audio seconds', track['duration'], flush=True)
    start = time.monotonic()
    annotation = pipeline(track['path'], sess_name=track['track'])
    timings.append({'track': track['track'], 'wall_seconds': time.monotonic() - start,
                    'audio_seconds': track['duration']})
    print('Completed', track['track'], 'wall seconds', timings[-1]['wall_seconds'], flush=True)
    with (a.output / (track['track'] + '.rttm')).open('w') as f:
        annotation.write_rttm(f)
    for interval, _, speaker in annotation.itertracks(yield_label=True):
        turns.append({'track': track['track'], 'label': str(speaker),
                      'start': float(interval.start), 'end': float(interval.end)})
result_id = uuid.uuid5(uuid.NAMESPACE_URL, 'diarizen-v2:' + ':'.join(t['sha256'] for t in manifest['tracks']))
speakers = [{'id': str(uuid.uuid5(result_id, track + ':' + label)).upper(), 'track': track,
             'label': label, 'providerName': 'DiariZen Large-s80-v2', 'confirmed': False}
            for track, label in sorted({(t['track'], t['label']) for t in turns})]
result = {'version': 1, 'id': str(result_id).upper(), 'generatedAt': time.time() - 978307200,
          'modelRevision': '027b3e221b9d81dce2be794084f1dbd3ba2da403',
          'providerName': 'DiariZen Large-s80-v2', 'ranges': turns, 'speakers': speakers,
          'trackSources': {t['track']: t['source'] for t in manifest['tracks']}}
(a.output / 'local-result.json').write_text(json.dumps(result, indent=2))
(a.output / 'stages.json').write_text(json.dumps({'device': 'cpu', 'threads': a.threads,
    'batch_size': a.batch_size, 'model_load_seconds': load_seconds, 'tracks': timings}, indent=2))
