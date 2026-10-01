"""Build private, blinded listening clips for independent speaker annotation.

Reviewers label speech, silence, overlap, and uncertain regions by listening.
Only reviewed annotations may serve as gold; saved transcripts are a system
under evaluation. Score random clips separately from disagreement diagnostics.
"""
import argparse
import hashlib
import itertools
import json
import math
from pathlib import Path
import random
import wave

from compare_reference import compare
from private_paths import private_output


def file_sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def select_random(total_frames, clip_frames, count, seed):
    """Uniform sample without replacement from fixed, nonoverlapping bins.

    A random grid origin includes the otherwise omitted remainder across seeds.
    If the recording is shorter than a clip, return the entire recording once.
    Selection uses no annotations or model outputs.
    """
    if min(total_frames, clip_frames, count) <= 0:
        raise ValueError('Audio length, clip length, and count must be positive')
    rng = random.Random(seed)
    if total_frames < clip_frames:
        return [(0, total_frames)]
    bins, remainder = divmod(total_frames, clip_frames)
    origin = rng.randrange(remainder + 1)
    chosen = sorted(rng.sample(range(bins), min(count, bins)))
    return [(origin + i * clip_frames, origin + (i + 1) * clip_frames) for i in chosen]


def validate_output(path, relative_files):
    output = private_output(path)
    if path.exists() or path.is_symlink():
        raise ValueError('Output directory must not already exist')
    for name in relative_files:
        private_output(output / name)
    return output


def intervals(rows, duration, model=False):
    clean = []
    for row in rows:
        if model and ((row.get('window_end_seconds', 0) > 0 and row.get('provisional') is not False) or row.get('update_id', 0) > 0
                      or 'update_index' in row):
            raise ValueError('Use full-file predictions, not window replay output')
        start, end = (row['start_seconds'], row['end_seconds']) if model else (row['start'], row['end'])
        speaker = row['speaker']
        if (not isinstance(speaker, str) or not speaker or
                not all(math.isfinite(x) for x in (start, end)) or
                not 0 <= start < duration or not start < end <= duration + 1e-6):
            raise ValueError('Invalid speaker interval or interval outside audio')
        clean.append(dict(start=start, end=min(end, duration), speaker=speaker))
    return clean


def clipped(rows, start, end):
    return [dict(start=max(row['start'], start) - start,
                 end=min(row['end'], end) - start, speaker=row['speaker'])
            for row in rows if row['start'] < end and row['end'] > start]


def diagnostics(systems, total, width, rate, random_clips, count):
    # Both directions include activity in the other system's unannotated gaps.
    # Permutation matching prevents different speaker names causing a disagreement.
    disagreements = []
    for left, right in itertools.combinations(systems, 2):
        for a, b in ((left, right), (right, left)):
            disagreements.extend(compare(a, b, total / rate)['review_intervals'])
    candidates = []
    for start in range(0, total - width + 1, width):
        end = start + width
        if any(start < b and end > a for a, b in random_clips):
            continue
        score = sum(max(0, min(end / rate, row['end']) - max(start / rate, row['start']))
                    * row['speaker_seconds'] / (row['end'] - row['start'])
                    for row in disagreements)
        if score > 0:
            candidates.append((score, start, end))
    candidates.sort(key=lambda item: (-item[0], item[1]))
    return [(a, b) for _, a, b in candidates[:count]]


def build(audio, reference, models, output, seconds=20.0, count=10, diagnostic_count=3, seed=0):
    if not math.isfinite(seconds) or seconds <= 0 or count <= 0 or diagnostic_count < 0:
        raise ValueError('Clip duration and count must be positive; diagnostic count cannot be negative')
    if not models:
        raise ValueError('Provide at least one model output')
    audio_hash = file_sha256(audio)
    with wave.open(str(audio), 'rb') as source:
        total, rate, params = source.getnframes(), source.getframerate(), source.getparams()
        width = round(seconds * rate)
        # Freeze the primary sample before reading any system annotations.
        random_clips = select_random(total, width, count, seed)
        reference_bytes = reference.read_bytes()
        ref = json.loads(reference_bytes)
        if 'preparedAudioSHA256' in ref and ref['preparedAudioSHA256'] != audio_hash:
            raise ValueError('Prepared audio SHA256 does not match the reference')
        if (not math.isfinite(ref['audioDurationSeconds']) or
                abs(ref['audioDurationSeconds'] - total / rate) > max(1 / rate, 1e-6)):
            raise ValueError('Reference duration must match prepared audio')
        systems = [intervals(ref['intervals'], total / rate)]
        input_hashes = [hashlib.sha256(reference_bytes).hexdigest()]
        for path in models:
            model_bytes = path.read_bytes()
            input_hashes.append(hashlib.sha256(model_bytes).hexdigest())
            systems.append(intervals([json.loads(line) for line in model_bytes.splitlines()
                                      if line.strip()], total / rate, model=True))
        extra = diagnostics(systems, total, width, rate, random_clips, diagnostic_count) if diagnostic_count else []
        selections = [(a, b, 'random') for a, b in random_clips] + [(a, b, 'diagnostic') for a, b in extra]
        random.Random(seed).shuffle(selections)
        names = [f'clip-{i:04d}' for i in range(1, len(selections) + 1)]
        files = ['private/key.json', 'blind/annotations.json'] + [f'blind/{name}.wav' for name in names]
        output = validate_output(output, files)
        output.mkdir(parents=True, mode=0o700)
        (output / 'blind').mkdir(mode=0o700)
        (output / 'private').mkdir(mode=0o700)
        key = dict(schema_version=1, seed=seed, audioDurationSeconds=total / rate, audio_path=str(audio.resolve()),
                   audio_sha256=audio_hash,
                   systems=[dict(id=f'system-{i:02d}', role='saved_reference_not_gold' if i == 0 else 'model',
                                 path=str(path.resolve()), sha256=input_hashes[i]) for i, path in enumerate([reference] + list(models))],
                   selection_policy='uniform_without_replacement_on_random_origin_nonoverlapping_grid',
                   requested_random_count=count, requested_diagnostic_count=diagnostic_count,
                   evaluation='Review blind clips first. Compare every system, including the saved reference, '
                   'against reviewed gold with permutation-invariant speaker matching. Report random and '
                   'diagnostic results separately. Exclude uncertain regions; retain reviewed silence and overlap.',
                   clips=[])
        annotations = dict(schema_version=1, clips=[])
        for name, (start, end, category) in zip(names, selections):
            source.setpos(start)
            data = source.readframes(end - start)
            if len(data) != (end - start) * params.nchannels * params.sampwidth:
                raise ValueError('WAV audio is truncated')
            with wave.open(str(output / 'blind' / f'{name}.wav'), 'wb') as target:
                target.setparams(params)
                target.writeframes(data)
            template = dict(id=name, audio=f'{name}.wav',
                            durationSeconds=(end - start) / rate, status='unreviewed',
                            instructions='Listen and label speech with anonymous speaker IDs consistent across '
                            'all clips from this meeting. Include overlapping speech. Leave silence unlabeled. '
                            'Add reviewedRegions only for audio you checked, excluding uncertain regions as gaps. '
                            'Set status to reviewed when annotation is complete.',
                            intervals=[], reviewedRegions=[])
            annotations['clips'].append(template)
            key['clips'].append(dict(id=name, category=category, startFrame=start, endFrame=end,
                                     wavSHA256=file_sha256(output / 'blind' / f'{name}.wav'),
                                     startSeconds=start / rate, endSeconds=end / rate,
                                     systems={f'system-{i:02d}': clipped(rows, start / rate, end / rate)
                                              for i, rows in enumerate(systems)}))
        (output / 'blind/annotations.json').write_text(json.dumps(annotations, indent=2) + '\n')
        (output / 'private/key.json').write_text(json.dumps(key, indent=2) + '\n')
    return key


def export_review(directory, output):
    """Export reviewed independent clips; manual status does not prove listening."""
    key = json.loads((directory / 'private/key.json').read_text())
    annotations = json.loads((directory / 'blind/annotations.json').read_text())
    clips = {clip['id']: clip for clip in annotations['clips']}
    if len(clips) != len(annotations['clips']):
        raise ValueError('Duplicate annotation clip IDs')
    gold = dict(status='reviewed', selection='independent',
                audioDurationSeconds=key['audioDurationSeconds'], reviewedRegions=[], intervals=[])
    predictions = {system['id']: [] for system in key['systems']}
    selected = [clip for clip in key['clips'] if clip['category'] == 'random']
    if not selected:
        raise ValueError('No independent clips to export')
    for selection in selected:
        clip = clips[selection['id']]
        start, end = selection['startSeconds'], selection['endSeconds']
        duration = end - start
        if clip['status'] != 'reviewed':
            raise ValueError('Review every independently sampled clip before exporting')
        if (not math.isfinite(clip['durationSeconds']) or
                abs(clip['durationSeconds'] - duration) > 1e-6):
            raise ValueError('Annotation duration does not match the private key')
        filename = f"{selection['id']}.wav"
        if Path(filename).name != filename or clip['audio'] != filename:
            raise ValueError('Annotation audio filename does not match the private key')
        clip_audio = directory / 'blind' / filename
        if file_sha256(clip_audio) != selection['wavSHA256']:
            raise ValueError('Clip WAV SHA256 does not match the private key')
        with wave.open(str(clip_audio), 'rb') as wav:
            if abs(wav.getnframes() / wav.getframerate() - duration) > 1e-6:
                raise ValueError('Clip WAV duration does not match the private key')
        regions = intervals([dict(region, speaker='coverage') for region in clip['reviewedRegions']], duration)
        if not regions:
            raise ValueError('Each reviewed clip needs at least one reviewed region')
        regions.sort(key=lambda region: region['start'])
        if any(a['end'] > b['start'] for a, b in zip(regions, regions[1:])):
            raise ValueError('Reviewed regions must not overlap')
        gold['reviewedRegions'].extend(dict(start=r['start'] + start, end=r['end'] + start) for r in regions)
        gold['intervals'].extend(dict(start=r['start'] + start, end=r['end'] + start, speaker=r['speaker'])
                                 for r in intervals(clip['intervals'], duration))
        for system, rows in selection['systems'].items():
            predictions[system].extend(dict(start=r['start'] + start, end=r['end'] + start, speaker=r['speaker'])
                                       for r in intervals(rows, duration))
    files = ['gold.json'] + [f'{system}.json' for system in predictions]
    output = validate_output(output, files)
    output.mkdir(parents=True, mode=0o700)
    (output / 'gold.json').write_text(json.dumps(gold, indent=2) + '\n')
    for system, rows in predictions.items():
        (output / f'{system}.json').write_text(json.dumps(dict(intervals=rows), indent=2) + '\n')
    return gold


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--export-reviewed', type=Path)
    parser.add_argument('--audio', type=Path)
    parser.add_argument('--reference', type=Path)
    parser.add_argument('--model', type=Path, action='append',
                        help='Full-file segment JSONL; repeat for each model')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--clip-seconds', type=float, default=20)
    parser.add_argument('--count', type=int, default=10)
    parser.add_argument('--diagnostic-count', type=int, default=3)
    parser.add_argument('--seed', type=int, default=0)
    args = parser.parse_args()
    try:
        if args.export_reviewed:
            export_review(args.export_reviewed, args.output)
            return
        if not args.audio or not args.reference or not args.model:
            parser.error('Building requires --audio, --reference, and --model')
        build(args.audio, args.reference, args.model, args.output, args.clip_seconds,
              args.count, args.diagnostic_count, args.seed)
    except (ValueError, OSError, KeyError, TypeError, wave.Error) as error:
        parser.error(str(error))


if __name__ == '__main__':
    main()
