"""Replay recorded callbacks against the real identity/People storage path at scale.

Requires a prebuilt macOS test bundle containing ObservationLiveScaleTests.
This copies the bundle before executing so concurrent builds cannot replace it.
Private evidence and all output remain in the requested private output directory.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, required=True)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--seconds', type=float, default=7200)
    parser.add_argument('--examples', type=int, default=8000)
    parser.add_argument('--load-note', default='Concurrent system load not controlled')
    parser.add_argument('--timeout', type=float, default=1200)
    args = parser.parse_args()
    if args.seconds <= 0 or args.examples < 0 or args.timeout <= 0:
        parser.error('seconds/timeout must be positive and examples must be nonnegative')
    sys.path.insert(0, str(ROOT / 'experiments/diarization-benchmark'))
    from private_paths import private_output
    output = private_output(args.output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    bundle = output / 'GdayMeetingsTests.xctest'
    shutil.copytree(args.bundle.resolve(), bundle)
    binary = bundle / 'Contents/MacOS/GdayMeetingsTests'
    swift = Path(subprocess.check_output(['xcrun', '--find', 'swift'], text=True).strip())
    helper = swift.parent.parent / 'libexec/swift/pm/swiftpm-testing-helper'
    developer = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
    bases = [developer, Path('/Applications/Xcode.app/Contents/Developer')]
    env = dict(os.environ, GDAY_OBSERVATION_SCALE_INPUT=str(args.input.resolve()),
               GDAY_OBSERVATION_SCALE_OUTPUT=str(output / 'metrics.json'),
               GDAY_OBSERVATION_SCALE_SECONDS=str(args.seconds),
               GDAY_OBSERVATION_SCALE_EXAMPLES=str(args.examples),
               GDAY_OBSERVATION_SCALE_LOAD_NOTE=args.load_note)
    env['DYLD_FRAMEWORK_PATH'] = ':'.join(str(base / relative) for base in bases for relative in
        ('Library/Developer/Frameworks', 'Platforms/MacOSX.platform/Developer/Library/Frameworks')
        if (base / relative).is_dir())
    env['DYLD_LIBRARY_PATH'] = ':'.join(str(base / relative) for base in bases for relative in
        ('Library/Developer/usr/lib', 'Platforms/MacOSX.platform/Developer/usr/lib')
        if (base / relative).is_dir())
    command = [str(helper), '--test-bundle-path', str(binary), '--testing-library', 'swift-testing',
               '--filter', 'ObservationLiveScaleTests']
    sources = sorted((args.package / 'Sources/GdayMeetings').rglob('*.swift'))
    sources += [args.package / 'Tests/GdayMeetingsTests/ObservationLiveScaleTests.swift', Path(__file__)]
    receipt = dict(binarySHA256=sha(binary), sourcesAtInvocation={str(p): sha(p) for p in sources},
                   inputs={str(args.input / name): sha(args.input / name)
                           for name in ('evidence.json', 'availability.json')},
                   command=command, audioSeconds=args.seconds, existingExamples=args.examples,
                   concurrentLoad=args.load_note,
                   provenanceNote='Copied binary is authoritative; invocation source snapshot does not prove build provenance.')
    receipt_path = output / 'receipt.json'
    receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
    start = time.monotonic()
    with (output / 'test.log').open('x') as log:
        process = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT)
        receipt['processID'] = process.pid
        receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
        try:
            code = process.wait(timeout=args.timeout)
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            process.terminate()
            try:
                code = process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                code = process.wait()
            receipt['interrupted'] = True
    receipt.update(returncode=code, elapsedSeconds=time.monotonic() - start,
                   logSHA256=sha(output / 'test.log'))
    metrics = output / 'metrics.json'
    if metrics.exists():
        receipt['metricsSHA256'] = sha(metrics)
    receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
    if code or not metrics.exists():
        raise RuntimeError(f'Scale replay failed; inspect {receipt_path}')
    print(json.dumps(dict(metrics=str(metrics), elapsedSeconds=receipt['elapsedSeconds'])))


if __name__ == '__main__':
    main()
