"""Stage a pinned, entirely local benchmark package and build its release executable."""
import argparse
import json
import re
import shutil
import subprocess
from pathlib import Path

PIN = '21493f8dac5a97e65742e6ff26f42f164c2fda0f'
root = Path(__file__).resolve().parent
repo = root.parents[1]
p = argparse.ArgumentParser()
p.add_argument('--cache', type=Path, default=repo/'apps/client-macos-swift/.build')
a = p.parse_args()
cache = a.cache.resolve()
source = cache/'checkouts/FluidAudio'
assert subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip() == PIN
subprocess.run(['git', '-C', str(source), 'diff', '--quiet', 'HEAD', '--', 'Sources', 'Package.swift', 'Package@swift-6.2.swift'], check=True)
artifact = cache/'artifacts/fluidaudio/NemoTextProcessing/NemoTextProcessing.xcframework'
assert artifact.is_dir(), 'Existing cached binary artifact is required; downloads are disabled.'
stage = root/'.local/package'
fluid = stage/'FluidAudio'
fluid.mkdir(parents=True, exist_ok=True)
link = fluid/'NemoTextProcessing.xcframework'
if not link.exists(): link.symlink_to(artifact, target_is_directory=True)
if (fluid/'Sources').exists(): shutil.rmtree(fluid/'Sources')
shutil.copytree(source/'Sources', fluid/'Sources')
for manifest in source.glob('Package*.swift'):
    text = manifest.read_text()
    text, count = re.subn(r'url:\s*"https://github.com/FluidInference/text-processing-rs/[^\"]+",\s*checksum:\s*"[^\"]+"', 'path: "NemoTextProcessing.xcframework"', text)
    assert count == 1, 'Unexpected upstream binary target; review before building.'
    (fluid/manifest.name).write_text(text)
benchmark = repo/'experiments/diarization-benchmark'
shutil.copytree(benchmark/'Sources', stage/'Sources', dirs_exist_ok=True)
manifest = (benchmark/'Package.swift').read_text()
manifest, count = re.subn(r'url: "https://github.com/FluidInference/FluidAudio.git",\s*revision: "'+PIN+r'",', 'path: "FluidAudio",', manifest)
assert count == 1
(stage/'Package.swift').write_text(manifest)
subprocess.run(['xcrun','swift','build','--package-path',str(stage),'-c','release','--jobs','2','--disable-sandbox','--cache-path',str(root/'.local/cache'),'--config-path',str(root/'.local/config'),'--security-path',str(root/'.local/security'),'--product','Community1Benchmark'], check=True)
print(stage/'.build/release/Community1Benchmark')
