#!/usr/bin/env python3
"""Summarize private local ASR receipts without copying transcript text into the report."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import re
from compare import PROVIDERS, digest, private_output, write_json


def covered_seconds(segments: list[dict], duration: float) -> float:
    intervals = sorted((max(0., s['start']), min(duration, s['end'])) for s in segments)
    total, end = 0., 0.
    for start, stop in intervals:
        total += max(0., stop - max(start, end))
        end = max(end, stop)
    return total


def metric_row(root: Path, track: dict, provider: str, candidate: tuple, original: dict) -> dict:
    iteration, path, value = candidate
    receipt = json.loads(path.with_suffix('.receipt.json').read_text())
    text = ''.join(segment['text'] for segment in value['segments'])
    original_text = ''.join(segment['text'] for segment in original['segments'])
    granularity = value.get('timestampGranularity')
    timed = granularity in ['segment','decoder-token-group']
    return dict(fixture=track['fixture'],track=track['track'],provider=provider,status=value['status'],
        selectedIteration=iteration,audioSeconds=track['durationSeconds'],model=value['model'],
        processLaunchWallSeconds=receipt['elapsedSeconds'],timing=value['timing'],resources=value['resources'],
        timingScope=value.get('timingScope'),timestampGranularity=granularity,diagnostics=value.get('diagnostics'),
        segments=len(value['segments']),nonemptySegments=sum(bool(s['text'].strip()) for s in value['segments']),
        textCharacters=len(text),hasText=bool(text.strip()),
        timedSpanSeconds=covered_seconds(value['segments'],track['durationSeconds']) if timed else None,
        firstTimedStart=min((s['start'] for s in value['segments']),default=None) if timed else None,
        lastTimedEnd=max((s['end'] for s in value['segments']),default=None) if timed else None,
        textUnchangedFromPrimary=text==original_text,resultSHA256=digest(path),
        executableSHA256=receipt['executableSHA256'],runnerSHA256=receipt.get('runnerSHA256'))


def summarize(root: Path, primary_iterations: dict[str,int] | None = None) -> dict:
    manifest = json.loads((root/'manifest.json').read_text())
    primary_iterations = primary_iterations or {}
    primary, review, history = [], [], []
    for track in manifest['tracks']:
        for provider in PROVIDERS:
            candidates = []
            folder = root/'results'/track['fixture']/track['track']
            for path in folder.glob(provider+'-*.json'):
                match = re.fullmatch(provider+r'-(\d+)\.json', path.name)
                if match:
                    value = json.loads(path.read_text())
                    if value.get('status') == 'completed':
                        candidates.append((int(match[1]), path, value))
            baseline_iteration = primary_iterations.get(track['fixture']+'/'+track['track'],0)
            baseline = next((c for c in candidates if c[0]==baseline_iteration),None)
            if baseline is None:
                raise ValueError('A designated primary matrix result is unavailable')
            primary.append(metric_row(root,track,provider,baseline,baseline[2]))
            review.append(metric_row(root,track,provider,max(candidates),baseline[2]))
            for candidate in sorted(candidates):
                if candidate[0] != baseline_iteration:
                    history.append(metric_row(root,track,provider,candidate,baseline[2]))
    return dict(schemaVersion=1,primaryMatrix=primary,reviewSelected=review,additionalRuns=history,
        primaryIterations=primary_iterations,completedPrimaryRows=len(primary),
        interpretation='Primary matrix is the designated original serial pass; latest successful runs serve the review page. System tracks are primary; microphone tracks are additional evidence. Counts and timestamp spans do not measure accuracy. Client resources exclude external services and accelerator allocations. Repeated invocations are fresh processes with reused system caches, not resident-model warm runs.')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--primary-config',type=Path,help='Private JSON map from fixture/track to designated primary iteration; default0')
    args=parser.parse_args()
    overrides=json.loads(args.primary_config.read_text()) if args.primary_config else {}
    write_json(private_output(args.output),summarize(private_output(args.root),overrides))
