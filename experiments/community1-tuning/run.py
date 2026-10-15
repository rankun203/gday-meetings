"""Run named single-variable ablations serially and export app-compatible acoustic turns."""
import argparse
import hashlib
import json
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent
MODEL_REVISION = 'df2625ac79a7ac6b65ad868fee6d80f320da4232'


def file_hash(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def normalize(profile, tracks):
    identity = uuid.uuid5(uuid.NAMESPACE_URL, profile + ':' + ':'.join(t['sha256'] for t in tracks))
    ranges = []
    for track in tracks:
        for row in track['segments']:
            start, end = row['start_seconds'], row['end_seconds']
            if not (0 <= start < end <= track['duration'] + .001):
                raise ValueError('Acoustic turn is outside its input track')
            ranges.append({'track': track['track'], 'label': row['speaker'], 'start': start, 'end': end})
    speakers = [{'id': str(uuid.uuid5(identity, track + ':' + label)).upper(), 'track': track,
                 'label': label, 'providerName': 'Community-1 ' + profile, 'confirmed': False}
                for track, label in sorted({(r['track'], r['label']) for r in ranges})]
    return {'version': 1, 'id': str(identity).upper(), 'generatedAt': time.time() - 978307200,
            'modelRevision': MODEL_REVISION, 'providerName': 'Community-1 ' + profile,
            'ranges': ranges, 'speakers': speakers,
            'trackSources': {t['track']: t['source'] for t in tracks}}


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--model-directory', type=Path, required=True)
    p.add_argument('--audio', type=Path, nargs=2, required=True, metavar=('MICROPHONE', 'SYSTEM'))
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--profiles', nargs='+', choices=['baseline', 'dense', 'overlap'], default=['baseline', 'dense'])
    p.add_argument('--execute', action='store_true', help='Run inference; otherwise write the private plan only.')
    a = p.parse_args()
    output = a.output.resolve()
    if not output.is_relative_to(ROOT/'.local') or output.exists():
        p.error('Choose a new output directory under this experiment’s .local directory.')
    if len(set(a.profiles)) != len(a.profiles): p.error('Profiles must be unique.')
    binary = ROOT/'.local/package/.build/release/Community1Benchmark'
    if not binary.is_file(): p.error('Build the local executable first.')
    manifest = a.model_directory/'manifest.json'
    if not manifest.is_file() or json.loads(manifest.read_text()).get('revision') != MODEL_REVISION:
        p.error('Prepare the verified pinned model links first.')
    tracks = [{'track': f'track{i}', 'source': source, 'path': str(path.resolve()),
               'sha256': file_hash(path)}
              for i, (path, source) in enumerate(zip(a.audio, ['microphone', 'system']))]
    output.mkdir(parents=True)
    plan = {'tracks': tracks, 'profiles': a.profiles, 'modelDirectory': str(a.model_directory.resolve()),
            'binarySHA256': file_hash(binary), 'executed': a.execute}
    (output/'plan.json').write_text(json.dumps(plan, indent=2))
    if not a.execute:
        print('Private plan prepared; inference has not started.')
        return
    # Match the app's float PCM decode before FluidAudio performs native 16 kHz conversion.
    for track in tracks:
        original = Path(track['path'])
        if original.suffix.lower() == '.opus':
            decoded = output/(track['track'] + '.wav')
            began = time.monotonic()
            subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-i', str(original),
                            '-map', '0:a:0', '-c:a', 'pcm_f32le', '-ar', '48000', str(decoded)], check=True)
            probe = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'a:0',
                '-show_entries', 'stream=sample_rate,channels,duration_ts,time_base', '-of', 'json', str(decoded)], text=True))['streams'][0]
            track.update(originalPath=str(original), originalSHA256=track['sha256'], path=str(decoded),
                         sha256=file_hash(decoded), decodePreparationSeconds=time.monotonic()-began,
                         decodedFormat=probe)
    plan['tracks'] = tracks
    (output/'plan.json').write_text(json.dumps(plan, indent=2))
    measure = ROOT.parent/'diarizen-comparison/measure.py'
    candidates = []
    for profile in a.profiles:
        directory = output/profile
        directory.mkdir()
        completed = []
        for track in tracks:
            segments = directory/(track['track'] + '-turns.jsonl')
            process = directory/(track['track'] + '-process.json')
            command = [str(binary), str(a.model_directory.resolve()), '--configuration', profile,
                       '--audio', track['path'], '--mode', 'offline', '--segments-output', str(segments)]
            print('Starting', profile, track['track'], flush=True)
            subprocess.run([sys.executable, str(measure), '--output', str(process), '--', *command], check=True)
            records = []
            for line in process.with_suffix('.log').read_text().splitlines():
                try: records.append(json.loads(line))
                except json.JSONDecodeError: continue
            stage = next(r for r in records if r.get('phase') == 'file_offline')
            config = next(r for r in records if r.get('phase') == 'configuration')
            completed.append({**track, 'duration': stage['audio_seconds'], 'stage': stage,
                              'configuration': config, 'process': json.loads(process.read_text()),
                              'segments': [json.loads(s) for s in segments.read_text().splitlines() if s]})
        result = directory/'local-result.json'
        result.write_text(json.dumps(normalize(profile, completed), indent=2))
        (directory/'metrics.json').write_text(json.dumps(completed, indent=2))
        candidates.append({'name': profile, 'path': str(result)})
    (output/'results.json').write_text(json.dumps(candidates, indent=2))
    print('Completed all requested profiles.')


if __name__ == '__main__': main()
