#!/usr/bin/env python3
"""Detect every track's speech and prepare uncapped Community-1 embedding windows."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import subprocess
import time

RATE = 16000
FRAME = 512
CONFIG = dict(sample_rate=RATE, frame_samples=FRAME, onset=0.5, offset=0.35,
              min_silence_ms=100, minimum_speech_ms=0, speech_padding_ms=0,
              target_window_seconds=5, minimum_window_seconds=2,
              short_policy='Extend symmetrically into recording context, clipped at file edges.',
              overlap_policy='Retain all speech; simultaneous speakers are not separated by VAD.',
              provider='CPUExecutionProvider', intra_op_threads=1, inter_op_threads=1)


def stable(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False)


def digest(path):
    with Path(path).open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()


def atomic_json(path, value):
    temporary = path.with_suffix(path.suffix + '.partial')
    temporary.write_text(stable(value))
    temporary.replace(path)


def speech_segments(probabilities, sample_count):
    """Apply Silero's onset/offset hysteresis, retaining arbitrarily short speech."""
    segments = []
    start = pending_end = None
    for index, probability in enumerate(probabilities):
        position = index * FRAME
        if not math.isfinite(float(probability)):
            raise ValueError('VAD returned a nonfinite probability.')
        if probability >= CONFIG['onset']:
            pending_end = None
            if start is None:
                start = position
        elif start is not None and probability < CONFIG['offset']:
            if pending_end is None:
                pending_end = position
            if position - pending_end >= RATE * CONFIG['min_silence_ms'] / 1000:
                if pending_end > start:
                    segments.append(dict(start_sample=start, end_sample=min(pending_end, sample_count)))
                start = pending_end = None
    if start is not None and start < sample_count:
        segments.append(dict(start_sample=start, end_sample=sample_count))
    return segments


def embedding_windows(segments, sample_count):
    """Divide long speech into disjoint windows; preserve short speech with context."""
    windows = []
    minimum = RATE * CONFIG['minimum_window_seconds']
    maximum = RATE * CONFIG['target_window_seconds']
    for index, segment in enumerate(segments):
        start, end = segment['start_sample'], segment['end_sample']
        if not 0 <= start < end <= sample_count:
            raise ValueError('Invalid VAD segment bounds.')
        if end - start < minimum:
            if sample_count < minimum:
                windows.append(dict(segment_index=index, status='recording_shorter_than_model_minimum',
                                    start_sample=0, end_sample=sample_count,
                                    speech_start_sample=start, speech_end_sample=end,
                                    context_padding_samples=sample_count - (end - start)))
                continue
            left = max(0, start - (minimum - (end - start)) // 2)
            left = min(left, sample_count - minimum)
            windows.append(dict(segment_index=index, status='short_speech_context_padded',
                                start_sample=left, end_sample=left + minimum,
                                speech_start_sample=start, speech_end_sample=end,
                                context_padding_samples=minimum - (end - start)))
            continue
        count = math.ceil((end - start) / maximum)
        for part in range(count):
            left = start + (end - start) * part // count
            right = start + (end - start) * (part + 1) // count
            windows.append(dict(segment_index=index, status='speech_only', start_sample=left,
                                end_sample=right, speech_start_sample=left, speech_end_sample=right,
                                context_padding_samples=0))
    # Context windows can overlap nearby speech and other windows. Quantify that support.
    ordered = sorted(windows, key=lambda w: (w['start_sample'], w['end_sample']))
    frontier = 0
    for window in ordered:
        window['overlap_with_previous_window_samples'] = max(0, min(frontier, window['end_sample']) - window['start_sample'])
        frontier = max(frontier, window['end_sample'])
        window['potential_mixed_speakers'] = bool(window['context_padding_samples'])
        window['speaker_overlap'] = 'unknown: speech detector does not separate simultaneous speakers'
    return windows


def coverage_samples(segments, windows):
    covered = 0
    for segment in segments:
        frontier = segment['start_sample']
        for window in sorted(windows, key=lambda w: w['start_sample']):
            left = max(frontier, segment['start_sample'], window['start_sample'])
            right = min(segment['end_sample'], window['end_sample'])
            if right > left:
                covered += right - left
                frontier = right
    return covered


def detect(path, session, probability_path):
    import numpy as np
    command = ['ffmpeg', '-v', 'error', '-nostdin', '-i', str(path), '-map', '0:a:0',
               '-ac', '1', '-ar', str(RATE), '-f', 'f32le', 'pipe:1']
    # Single-recording state prevents information leaking across files or meetings.
    state = np.zeros((2, 1, 128), dtype=np.float32)
    context = np.zeros((1, 64), dtype=np.float32)
    probabilities = []
    sample_count = 0
    error_path = probability_path.with_suffix('.decode.log')
    with error_path.open('wb') as errors, probability_path.with_suffix('.partial').open('wb') as output:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=errors)
        try:
            while True:
                data = process.stdout.read(FRAME * 4)
                if not data:
                    break
                if len(data) % 4:
                    raise ValueError('Decoder returned an incomplete float sample.')
                values = np.frombuffer(data, dtype='<f4')
                if not np.isfinite(values).all():
                    raise ValueError('Decoder returned nonfinite audio.')
                sample_count += len(values)
                if len(values) < FRAME:
                    values = np.pad(values, (0, FRAME - len(values)))
                chunk = values.reshape(1, FRAME)
                inputs = np.concatenate((context, chunk), axis=1)
                probability, state = session.run(None, {'input': inputs, 'state': state,
                                                        'sr': np.array(RATE, dtype=np.int64)})
                value = float(probability.reshape(-1)[0])
                probabilities.append(value)
                output.write(np.asarray([value], dtype='<f4').tobytes())
                context = chunk[:, -64:].copy()
            if process.wait() != 0:
                raise RuntimeError(f'Audio decoding failed; inspect {error_path.name}.')
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdout.close()
    if sample_count == 0:
        raise ValueError('Audio recording contains no decoded samples.')
    probability_path.with_suffix('.partial').replace(probability_path)
    return sample_count, probabilities, command


def tracks_for(meeting, root):
    directory = root / 'library/meetings' / meeting['folder']
    directory.resolve().relative_to((root / 'library/meetings').resolve())
    names = set(meeting.get('metadata', {}).get('audioFiles', []))
    names.update(p.name for p in directory.iterdir() if p.suffix.lower() in {'.opus', '.wav', '.m4a', '.caf', '.mp3', '.flac'})
    for name in sorted(names):
        path = directory / name
        path.resolve().relative_to(directory.resolve())
        if path.is_symlink() or not path.is_file():
            raise ValueError('Recording is missing or is a symbolic link.')
        yield name, path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--inventory', type=Path, required=True, help='Existing isolated input; used for meeting inventory only.')
    parser.add_argument('--vad-model', type=Path, required=True)
    parser.add_argument('--max-recordings', type=int, default=0, help='Benchmark; incomplete runs do not publish input.json.')
    args = parser.parse_args()
    import numpy as np
    import onnxruntime as ort
    root = args.root.resolve()
    root.mkdir(parents=True, exist_ok=True)
    inventory = json.loads(args.inventory.read_text())
    receipt = dict(configuration=CONFIG, inventory_sha256=digest(args.inventory),
                   model_sha256=digest(args.vad_model), model_filename=args.vad_model.name,
                   source_sha256=digest(Path(__file__)), numpy_version=np.__version__,
                   onnxruntime_version=ort.__version__,
                   ffmpeg_version=subprocess.run(['ffmpeg', '-version'], capture_output=True, text=True, check=True).stdout.splitlines()[0],
                   upstream='https://github.com/snakers4/silero-vad/blob/master/src/silero_vad/utils_vad.py')
    receipt_path = root / 'full-speech-provenance.json'
    if receipt_path.exists() and json.loads(receipt_path.read_text()) != receipt:
        raise ValueError('VAD inputs changed; use a new output directory.')
    atomic_json(receipt_path, receipt)
    options = ort.SessionOptions()
    options.intra_op_num_threads = options.inter_op_num_threads = 1
    session = ort.InferenceSession(str(args.vad_model), providers=['CPUExecutionProvider'], sess_options=options)
    cache = root / 'vad'
    cache.mkdir(exist_ok=True)
    recordings = []
    examples = []
    meetings = inventory['meetings']
    all_tracks = [(meeting, name, path) for meeting in meetings for name, path in tracks_for(meeting, root)]
    for meeting, name, path in all_tracks[:args.max_recordings or None]:
        source_hash = digest(path)
        identity = [meeting['id'], name, source_hash]
        track_key = hashlib.sha256(stable(identity).encode()).hexdigest()
        checkpoint = cache / (track_key + '.json')
        probability_path = cache / (track_key + '.probabilities.f32')
        record = json.loads(checkpoint.read_text()) if checkpoint.exists() else None
        if record and record.get('status') == 'complete':
            if not probability_path.exists() or digest(probability_path) != record['probabilities_sha256']:
                raise ValueError('VAD probability checkpoint changed.')
        else:
            started = time.monotonic()
            try:
                sample_count, probabilities, command = detect(path, session, probability_path)
                segments = speech_segments(probabilities, sample_count)
                windows = embedding_windows(segments, sample_count)
                total = sum(s['end_sample'] - s['start_sample'] for s in segments)
                covered = coverage_samples(segments, windows)
                if covered != total:
                    raise ValueError('Embedding windows do not cover every detected speech sample.')
                record = dict(status='complete', meeting_id=meeting['id'], audio_file=name,
                              audio_sha256=source_hash, decoded_samples=sample_count,
                              duration_seconds=sample_count / RATE, segments=segments, windows=windows,
                              detected_speech_samples=total, covered_speech_samples=covered,
                              probabilities_file=str(probability_path.relative_to(root)),
                              probabilities_sha256=digest(probability_path), frames=len(probabilities),
                              decode_command=command, seconds=time.monotonic() - started)
                if digest(path) != source_hash:
                    raise ValueError('Source audio changed during detection.')
            except Exception as error:
                record = dict(status='failed', meeting_id=meeting['id'], audio_file=name,
                              audio_sha256=source_hash, error=str(error), seconds=time.monotonic() - started)
            atomic_json(checkpoint, record)
        recordings.append(record)
        print(stable(dict(recording=len(recordings), total=len(all_tracks), status=record['status'],
                          seconds=record['seconds'], segments=len(record.get('segments', [])),
                          windows=len(record.get('windows', [])))), flush=True)
        for window in record.get('windows', []):
            start, end = window['start_sample'] / RATE, window['end_sample'] / RATE
            identifier = hashlib.sha256(stable([identity, window]).encode()).hexdigest()
            examples.append(dict(id=identifier, meetingID=meeting['id'], audioFile=name,
                                 audioRevision=source_hash, source=Path(name).stem,
                                 start=start, end=end, spans=[dict(start=start, end=end)],
                                 origin='full-recording-speech-detection', review='unassigned',
                                 excluded=window['status'] == 'recording_shorter_than_model_minimum',
                                 speechSpans=[dict(start=window['speech_start_sample'] / RATE,
                                                   end=window['speech_end_sample'] / RATE)],
                                 speech_detection=window))
    complete = len(recordings) == len(all_tracks) and all(r['status'] == 'complete' for r in recordings)
    manifest = dict(configuration=CONFIG, recordings=recordings,
                    summary=dict(recordings_expected=len(all_tracks), recordings_attempted=len(recordings),
                                 recordings_failed=sum(r['status'] != 'complete' for r in recordings),
                                 windows=len(examples), excluded_windows=sum(e['excluded'] for e in examples),
                                 speech_seconds=sum(r.get('detected_speech_samples', 0) for r in recordings) / RATE,
                                 covered_seconds=sum(r.get('covered_speech_samples', 0) for r in recordings) / RATE,
                                 complete=complete))
    atomic_json(root / 'full-speech-manifest.json', manifest)
    if complete:
        output = {**inventory, 'meetings': meetings, 'examples': examples, 'samples': [],
                  'cached_turns': [], 'decisions': [],
                  'metadata': {**inventory['metadata'], 'full_speech': manifest['summary'],
                               'limitations': ['VAD does not separate simultaneous speakers. Short speech includes explicitly recorded context.',
                                               'Local speaker labels and saved examples do not select detection or embedding windows.']}}
        atomic_json(root / 'input.json', output)
    print(stable(manifest['summary']), flush=True)
    if not complete and not args.max_recordings:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
