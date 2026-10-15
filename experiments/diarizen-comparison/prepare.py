"""Prepare identical private 16 kHz mono WAV inputs; never print source paths."""
import argparse
import hashlib
import json
import subprocess
import wave
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--target', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
folder = Path(json.loads(a.target.read_text())['folder'])
metadata = json.loads((folder / 'content.json').read_text())
a.output.mkdir(parents=True, exist_ok=True)
tracks = []
for index, filename in enumerate(metadata['audioFiles']):
    source = folder / filename
    output = a.output / f'track{index}.wav'
    subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-y', '-i', str(source),
                    '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le', str(output)], check=True)
    with wave.open(str(output)) as wav:
        duration = wav.getnframes() / wav.getframerate()
    stem = source.stem.lower()
    kind = 'microphone' if stem in {'mic', 'microphone'} else 'system' if stem in {'system', 'system_mix'} else 'unknown'
    tracks.append({'track': f'track{index}', 'source': kind, 'path': str(output.resolve()),
                   'duration': duration, 'sha256': hashlib.sha256(output.read_bytes()).hexdigest()})
(a.output / 'inputs.json').write_text(json.dumps({'version': 1, 'tracks': tracks}, indent=2))
print(json.dumps({'prepared_tracks': len(tracks), 'audio_seconds': sum(t['duration'] for t in tracks)}))
