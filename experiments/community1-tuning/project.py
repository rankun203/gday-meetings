"""Project every candidate from immutable ASR segments and compare final aligned labels."""
import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from run import ROOT, file_hash

p = argparse.ArgumentParser()
p.add_argument('--run', type=Path, required=True)
p.add_argument('--projector-checkout', type=Path, required=True)
p.add_argument('--source-artifact', type=Path, required=True)
p.add_argument('--remote', type=Path, required=True)
p.add_argument('--state', type=Path, required=True)
a = p.parse_args()
directory = a.run.resolve()
if not directory.is_relative_to(ROOT/'.local'): p.error('Use a private run under .local.')
rows = json.loads(a.source_artifact.read_text())['segments']
if not rows or not all(r.get('timing', {}).get('text') == r['text'] for r in rows):
    raise ValueError('The immutable source must preserve current text timing.')
source = directory/'immutable-source.jsonl'
source.write_text(''.join(json.dumps(r, ensure_ascii=False)+'\n' for r in rows))
plan = json.loads((directory/'plan.json').read_text())
metrics = json.loads((directory/plan['profiles'][0]/'metrics.json').read_text())
tracks = [{key: t[key] for key in ['track','source','path','sha256','duration']} for t in metrics]
for track in plan['tracks']:
    for path_key, hash_key in [('path','sha256'),('originalPath','originalSHA256')]:
        if path_key in track:
            assert file_hash(track[path_key]) == track[hash_key]
inputs = directory/'inputs.json'
inputs.write_text(json.dumps({'version': 1, 'tracks': tracks}, indent=2))
output = directory/'projections'
output.mkdir(exist_ok=True)
checkout = a.projector_checkout.resolve()
binary = checkout/'apps/client-macos-swift/.build/out/Products/Release/GdayMeetingsTests.xctest/Contents/MacOS/GdayMeetingsTests'
swift = Path(subprocess.check_output(['xcrun','--find','swift'], text=True).strip())
developer = Path(subprocess.check_output(['xcode-select','-p'], text=True).strip())
env = dict(os.environ)
env.update(GDAY_DIARIZATION_BENCHMARK='project', GDAY_DIARIZATION_BENCHMARK_INPUTS=str(inputs),
           GDAY_DIARIZATION_BENCHMARK_OUTPUT=str(output), GDAY_DIARIZATION_BENCHMARK_TRANSCRIPT=str(source),
           GDAY_DIARIZATION_BENCHMARK_RESULTS=str(directory/'results.json'),
           DYLD_FRAMEWORK_PATH=str(developer/'Library/Developer/Frameworks'),
           DYLD_LIBRARY_PATH=str(developer/'Library/Developer/usr/lib'))
subprocess.run([str(swift.parent.parent/'libexec/swift/pm/swiftpm-testing-helper'),
    '--test-bundle-path',str(binary),'--testing-library','swift-testing','--filter','DiarizationComparisonHarnessTests'],
    env=env, cwd=checkout, check=True)
with tempfile.TemporaryDirectory(prefix='community1-agreement-') as temporary:
    for profile in plan['profiles']:
        result = Path(temporary)/(profile+'-agreement.json')
        subprocess.run([sys.executable,str(ROOT.parent/'runpod-output-comparison/compare.py'),
            '--local',str(output/(profile+'-transcript.jsonl')),'--remote',str(a.remote.resolve()),
            '--state',str(a.state.resolve()),'--out',str(result)],check=True)
        (directory/result.name).write_bytes(result.read_bytes())
(output/'provenance.json').write_text(json.dumps({'sourceRows':len(rows),
    'sourceTimedSpans':sum(len(r['timing']['spans']) for r in rows),
    'sourceSHA256':file_hash(a.source_artifact),
    'projectorSHA256':file_hash(binary),
    'originalAndDecodedAudioHashesVerified':True},indent=2))
print('Projection and conditional final-label comparison completed; original and decoded hashes verified.')
