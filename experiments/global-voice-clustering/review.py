"""Serve the private experiment and save review feedback outside the source tree."""
import argparse
import hashlib
import json
import math
import re
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse, parse_qs

from transcript import build_transcripts


def load_variant(root, results, method, variant):
    """Serve a catalog entry only, keeping its declared file within the run."""
    if not all(re.fullmatch(r'[A-Za-z0-9_-]+', value) for value in (method, variant)):
        raise ValueError('Invalid comparison variant.')
    entry = next((entry for entry in results.get('method_catalog', []) if entry.get('id') == method), None)
    selected = next((item for item in (entry or {}).get('variants', []) if item.get('id') == variant), None)
    if selected is None:
        raise ValueError('Comparison variant is unavailable.')
    relative = Path(selected.get('path', ''))
    if relative.is_absolute() or relative.parts != ('variants', method, variant + '.json'):
        raise ValueError('Comparison variant has an invalid path.')
    root = root.resolve()
    path = (root / relative).resolve()
    if not path.is_relative_to(root) or not path.is_file():
        raise ValueError('Comparison variant file is unavailable.')
    body = path.read_bytes()
    if selected.get('sha256') and hashlib.sha256(body).hexdigest() != selected['sha256']:
        raise ValueError('Comparison variant changed after this run was loaded.')
    value = json.loads(body)
    if value.get('method') != method or value.get('variant') != variant or not isinstance(value.get('assignments'), dict):
        raise ValueError('Comparison variant has invalid assignments or identity.')
    return value


def review_rows(source, root):
    meetings = {m['id']: m for m in source['meetings']}
    vectors = {s.get('example_id', s['id']): s for s in source['samples']}
    rows = []
    for example in source.get('examples', []):
        row = dict(example)
        m = meetings[row['meetingID']]
        speaker = next((s for s in m.get('speakers', []) if s.get('id') == row.get('speakerID')), {})
        row.update(sample_id=row['id'], meeting_id=row['meetingID'],
                   meeting_order=m['meeting_order'],
                   local_label=row.get('detectedSpeakerID') or speaker.get('label') or speaker.get('name'),
                   support_spans=row.get('spans') or [dict(start=row.get('start'), end=row.get('end'))],
                   audio_path=str(root / 'library/meetings' / m['folder'] / row.get('audioFile', '')))
        vector = vectors.get(row['id'])
        if vector:
            row['sample_id'] = vector['id']
            row['audio_path'] = vector['audio_path']
            row['support_spans'] = vector.get('support_spans', row['support_spans'])
            row['speech_detection'] = vector.get('speech_detection')
        row['physical_key'] = (vector or {}).get('density_key') or hashlib.sha256(json.dumps(
            [row['meetingID'], row.get('audioFile'), row.get('audioRevision'), row['support_spans']],
            sort_keys=True).encode()).hexdigest()
        rows.append(row)
    return sorted(rows, key=lambda row: (row['meeting_order'], row.get('start') or 0, row['sample_id']))


def build_payload(root):
    source_path = root / ('review-input.json' if (root / 'review-input.json').exists() else 'enriched-input.json' if (root / 'enriched-input.json').exists() else 'input.json')
    source = json.loads(source_path.read_text())
    results = json.loads((root / 'results.json').read_text())
    source_hash = hashlib.sha256(source_path.read_bytes()).hexdigest()
    if results.get('metadata', {}).get('input_sha256') != source_hash:
        raise ValueError('Comparison results do not match the input. Run compare.py again.')
    # Vectors and machine-specific paths have no role in listening review.
    samples = review_rows(source, root)
    clean = []
    for sample in samples:
        fields = ('sample_id', 'meeting_id', 'meeting_order', 'local_label', 'source', 'support_spans',
                  'personID', 'review', 'origin', 'excluded', 'manuallyCleared', 'start', 'end', 'physical_key', 'speech_detection')
        row = {k: sample[k] for k in fields if k in sample}
        row['sample_id'] = sample.get('sample_id', sample.get('id'))
        clean.append(row)
    return dict(meetings=[{**{k: m['metadata'].get(k) for k in ('id', 'title', 'createdAt', 'duration', 'audioFiles')},
                          'meeting_order': m['meeting_order']} for m in source['meetings']], samples=clean,
                people=[dict(id=p['id'], name=p.get('name', 'Unnamed person')) for p in source.get('people', [])],
                transcripts=build_transcripts(source, root, samples),
                availability=source.get('metadata', {}),
                results=results,
                dataset=source_hash)


def runtime_sections(payload):
    """Prepare immutable responses without sending every assignment on startup."""
    results = payload['results']
    catalog = results.get('method_catalog')
    if not catalog or any(entry['id'] not in results.get('methods', {}) for entry in catalog):
        raise ValueError('This review requires a current model catalog. Open the current comparison run.')
    methods = {entry['id']: {key: value for key, value in results['methods'][entry['id']].items()
                            if key != 'assignments'} for entry in catalog}
    bootstrap = {key: payload[key] for key in ('dataset', 'meetings', 'people', 'availability')}
    bootstrap['results'] = dict(method_catalog=catalog, methods=methods)
    counts = {}
    for entry in catalog:
        assignments = results['methods'][entry['id']].get('assignments', {})
        per_meeting = {meeting['id']: 0 for meeting in payload['meetings']}
        for sample in payload['samples']:
            if sample['sample_id'] in assignments:
                per_meeting[sample['meeting_id']] += 1
        counts[entry['id']] = per_meeting
    bootstrap['meeting_counts'] = counts
    pairs = results.get('pair_review', {})
    bootstrap['has_pair_review'] = bool(pairs.get('pairs'))
    ids = {sid for pair in pairs.get('pairs', []) for sid in pair['sample_ids']}
    contexts, best = {}, {}
    sample_meetings = {sample['sample_id']: sample['meeting_id'] for sample in payload['samples']}
    finite = lambda value: type(value) in (int, float) and math.isfinite(value)
    for row in payload['transcripts']['rows']:
        if not row.get('id') or not finite(row.get('start')) or not finite(row.get('end')) or row['end'] <= row['start']:
            continue
        intervals = {}
        for span in row.get('coverage_intervals', []):
            sid = span['sample_id']
            if (sid in ids and row['meeting_id'] == sample_meetings.get(sid)
                    and finite(span.get('start')) and finite(span.get('end'))):
                a, b = max(row['start'], span['start']), min(row['end'], span['end'])
                if b > a:
                    intervals.setdefault(sid, []).append((a, b))
        for sid, spans in intervals.items():
            covered, tail = 0, float('-inf')
            for a, b in sorted(spans):
                if b > tail:
                    covered += b - max(a, tail)
                    tail = b
            rank = (-round(covered, 9), row['start'], str(row['id']))
            if sid in best and best[sid] <= rank:
                continue
            best[sid] = rank
            track = row.get('track_index')
            track = track if type(track) is int and track >= 0 else 'all'
            meeting = row['meeting_id']
            offset = row.get('recording_offset') if finite(row.get('recording_offset')) else 0
            audio_start = row.get('audio_start') if finite(row.get('audio_start')) else row['start'] - offset
            contexts[sid] = dict(view='transcript', meeting=meeting, row=row['id'], track=track,
                                 audio=f'mix:{meeting}' if track == 'all' else f'recording:{meeting}:{track}',
                                 time=max(0, row['start'] if track == 'all' else audio_start),
                                 rowFilter='all', page=0, transcriptScroll=0, scroll=0)
    sections = dict(compare=dict(samples=[sample for sample in payload['samples'] if sample['sample_id'] in ids],
                                 pair_contexts=contexts, results=dict(pair_review=pairs)),
                    evidence=dict(samples=payload['samples']),
                    transcripts=dict(transcripts=payload['transcripts']),
                    details=dict(results={key: value for key, value in results.items()
                                          if key not in ('methods', 'method_catalog', 'pair_review', 'scenarios')}),
                    arrival=dict(results=dict(scenarios=results.get('scenarios', []),
                                              synthetic_lifecycle=results.get('synthetic_lifecycle'))))
    encode = lambda value: json.dumps(value, separators=(',', ':')).encode()
    responses = {'/data.json': encode(bootstrap)}
    responses.update({f'/section/{key}.json': encode(value) for key, value in sections.items()})
    responses.update({f'/method/{entry["id"]}.json': encode(results['methods'][entry['id']])
                      for entry in catalog})
    return responses


def prepare_clip(audio, spans, output):
    """Seek before decoding each excerpt, so late passages cost only their duration."""
    command = ['ffmpeg', '-v', 'error', '-nostdin', '-y']
    filters = []
    for index, span in enumerate(spans):
        duration = float(span['end']) - float(span['start'])
        command += ['-ss', str(float(span['start'])), '-t', str(duration), '-i', str(audio)]
        filters.append(f'[{index}:a]atrim=duration={duration},asetpts=PTS-STARTPTS[a{index}]')
    filters.append(''.join(f'[a{i}]' for i in range(len(spans)))
                   + f'concat=n={len(spans)}:v=0:a=1[out]')
    temp = output.with_suffix('.partial.wav')
    try:
        subprocess.run(command + ['-filter_complex', ';'.join(filters), '-map', '[out]',
                                  '-ar', '16000', '-ac', '1', str(temp)],
                       check=True, capture_output=True, timeout=120)
        temp.replace(output)
    finally:
        temp.unlink(missing_ok=True)


def mixed_recording(root, meeting_id, tracks, recordings):
    """Build one seekable conversation stream from the immutable copied tracks."""
    inputs = []
    for track in tracks:
        audio = recordings[track['recording_key']].resolve()
        offset = track.get('recording_offset', 0)
        if not audio.is_relative_to(root) or not audio.is_file():
            raise ValueError('A copied recording is unavailable.')
        if not isinstance(offset, (int, float)) or not math.isfinite(offset) or offset < 0:
            raise ValueError('A recording has an invalid offset.')
        inputs.append((audio, offset))
    if not inputs:
        raise ValueError('This meeting has no recording.')
    cache = root / 'mixed-recordings'
    cache.mkdir(exist_ok=True)
    receipt = [(str(p), p.stat().st_size, p.stat().st_mtime_ns, offset) for p, offset in inputs]
    name = hashlib.sha256(json.dumps([meeting_id, receipt]).encode()).hexdigest()
    output = cache / (name + '.wav')
    if output.exists():
        return output
    command = ['ffmpeg', '-v', 'error', '-nostdin', '-y']
    for audio, _ in inputs:
        command += ['-i', str(audio)]
    filters = [f'[{i}:a]aresample=16000,aformat=channel_layouts=mono,adelay={round(offset*1000)}:all=1[a{i}]'
               for i, (_, offset) in enumerate(inputs)]
    filters.append(''.join(f'[a{i}]' for i in range(len(inputs)))
                   + f'amix=inputs={len(inputs)}:duration=longest:dropout_transition=0:normalize=0,alimiter=level=false:latency=true[out]')
    temp = output.with_suffix('.partial.wav')
    try:
        subprocess.run(command + ['-filter_complex', ';'.join(filters), '-map', '[out]',
                                  '-ar', '16000', '-ac', '1', str(temp)],
                       check=True, capture_output=True, timeout=180)
        temp.replace(output)
    finally:
        temp.unlink(missing_ok=True)
    return output


def serve(root, port, feedback_directory=None):
    root = root.resolve()
    payload = build_payload(root)
    responses = runtime_sections(payload)
    variant_responses = {}
    source_path = root / ('review-input.json' if (root / 'review-input.json').exists() else 'enriched-input.json' if (root / 'enriched-input.json').exists() else 'input.json')
    source = json.loads(source_path.read_text())
    rows = review_rows(source, root)
    by_id = {str(s.get('sample_id', s.get('id'))): s for s in rows}
    recordings = {f'{m["id"]}/{i}': root / 'library/meetings' / m['folder'] / name
                  for m in source['meetings'] for i, name in enumerate(m['metadata'].get('audioFiles', []))}
    clips = root / 'clips'
    clips.mkdir(exist_ok=True)
    lock = threading.Lock()
    preparation_locks = {}
    preparation_lock_guard = threading.Lock()

    def preparation_lock(key):
        with preparation_lock_guard:
            return preparation_locks.setdefault(key, threading.Lock())
    feedback_root = feedback_directory.resolve() if feedback_directory else root
    feedback_root.mkdir(parents=True, exist_ok=True)
    feedback = feedback_root / f'feedback-{payload["dataset"][:16]}.json'

    def feedback_value():
        if feedback.exists():
            return json.loads(feedback.read_text())
        return dict(revision=0, dataset=payload['dataset'], reviews={}, notes='')

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def send(self, body, content_type='application/json', status=200):
            if not isinstance(body, bytes):
                body = json.dumps(body).encode()
            self.send_response(status)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.end_headers()
            self.wfile.write(body)

        def send_audio(self, audio, content_type):
            size = audio.stat().st_size
            start, end = 0, size - 1
            byte_range = self.headers.get('Range')
            if byte_range:
                if not byte_range.startswith('bytes=') or ',' in byte_range:
                    return self.send({'error': 'Unsupported range'}, status=416)
                first, last = byte_range[6:].split('-', 1)
                start = int(first) if first else max(0, size - int(last))
                end = min(size - 1, int(last)) if first and last else size - 1
                if not 0 <= start <= end < size:
                    return self.send({'error': 'Range outside audio'}, status=416)
            self.send_response(206 if byte_range else 200)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(end - start + 1))
            self.send_header('Accept-Ranges', 'bytes')
            if byte_range:
                self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
            self.end_headers()
            with audio.open('rb') as handle:
                handle.seek(start)
                remaining = end - start + 1
                while remaining:
                    chunk = handle.read(min(65536, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
            return

        def do_GET(self):
            path = unquote(urlparse(self.path).path)
            try:
                if path == '/':
                    return self.send(Path(__file__).with_name('review.html').read_bytes(), 'text/html; charset=utf-8')
                if path == '/review.js':
                    return self.send(Path(__file__).with_name('review.js').read_bytes(), 'text/javascript')
                if path == '/review_state.js':
                    return self.send(Path(__file__).with_name('review_state.js').read_bytes(), 'text/javascript')
                if path in responses:
                    return self.send(responses[path])
                if path.startswith('/sample/') and path.endswith('.json'):
                    sid = path.removeprefix('/sample/').removesuffix('.json')
                    if sid not in by_id:
                        raise ValueError('Sample is unavailable.')
                    requested = parse_qs(urlparse(self.path).query)
                    comparisons = []
                    for entry in payload['results']['method_catalog']:
                        method = entry['id']
                        variant = requested.get(method, [entry.get('default_variant', 'saved')])[0]
                        if variant == entry.get('default_variant', 'saved'):
                            value = payload['results']['methods'][method]
                        else:
                            value = load_variant(root, payload['results'], method, variant)
                        comparisons.append(dict(method=method, variant=variant,
                                                assignment=value.get('assignments', {}).get(sid)))
                    return self.send(comparisons)
                if path == '/feedback.json':
                    with lock:
                        return self.send(feedback_value())
                if path.startswith('/variant/'):
                    parts = path.split('/')
                    if len(parts) != 4 or not parts[3].endswith('.json'):
                        raise ValueError('Invalid comparison variant URL.')
                    with preparation_lock(path):
                        if path not in variant_responses:
                            variant_responses[path] = json.dumps(load_variant(root, payload['results'], parts[2], parts[3][:-5]), separators=(',', ':')).encode()
                    return self.send(variant_responses[path])
                if path.startswith('/mix/'):
                    meeting_id = path.removeprefix('/mix/')
                    receipt = next((m for m in payload['transcripts']['meetings'] if m['meeting_id'] == meeting_id), None)
                    if receipt is None:
                        raise ValueError('Meeting is unavailable.')
                    with preparation_lock('mix:' + meeting_id):
                        audio = mixed_recording(root, meeting_id, receipt.get('audio_tracks', []), recordings)
                    return self.send_audio(audio, 'audio/wav')
                if path.startswith('/recording/'):
                    audio = recordings[path.removeprefix('/recording/')].resolve()
                    if not audio.is_relative_to(root) or not audio.is_file():
                        raise ValueError('Copied recording is unavailable.')
                    return self.send_audio(audio, 'audio/ogg' if audio.suffix == '.opus' else 'audio/mp4')
                if path.startswith('/clip/'):
                    sid = path.removeprefix('/clip/').removesuffix('.wav')
                    row = by_id[sid]
                    audio = Path(row['audio_path'])
                    if not audio.is_absolute():
                        audio = root / audio
                    audio = audio.resolve()
                    if not audio.is_relative_to(root) or not audio.is_file():
                        raise ValueError('Copied audio is unavailable.')
                    spans = row.get('support_spans') or row.get('spans') or [dict(start=row['start'], end=row['end'])]
                    if not spans or any(not isinstance(s.get('start'), (float, int)) or
                                        not isinstance(s.get('end'), (float, int)) or
                                        not 0 <= s['start'] < s['end'] for s in spans):
                        raise ValueError('This sample has no valid playback range.')
                    name = hashlib.sha256(json.dumps([str(audio), spans]).encode()).hexdigest()
                    output = clips / (name + '.wav')
                    # Cached clips never queue behind another recording's preparation.
                    if not output.exists():
                        with preparation_lock(name):
                            if not output.exists():
                                prepare_clip(audio, spans, output)
                    return self.send_audio(output, 'audio/wav')
                self.send({'error': 'Not found'}, status=404)
            except (KeyError, ValueError, OSError, subprocess.SubprocessError) as error:
                self.send({'error': str(error)}, status=422)

        def do_POST(self):
            if self.path != '/feedback.json':
                return self.send({'error': 'Not found'}, status=404)
            if self.headers.get('Origin') != f'http://127.0.0.1:{port}':
                return self.send({'error': 'Save feedback from the local review page.'}, status=403)
            try:
                length = int(self.headers.get('Content-Length', 0))
                if not 0 < length < 10_000_000:
                    raise ValueError('Feedback size is invalid.')
                body = json.loads(self.rfile.read(length))
                with lock:
                    current = feedback_value()
                    if body.get('revision') != current['revision'] or body.get('dataset') != payload['dataset']:
                        return self.send({'error': 'Feedback changed in another tab. Export your edits, then reload.'}, status=409)
                    if not isinstance(body.get('reviews'), dict) or not isinstance(body.get('notes'), str):
                        raise ValueError('Feedback format is invalid.')
                    body['revision'] += 1
                    temp = feedback.with_suffix('.partial.json')
                    temp.write_text(json.dumps(body, indent=2))
                    temp.replace(feedback)
                self.send(body)
            except (ValueError, OSError) as error:
                self.send({'error': str(error)}, status=400)

    server = ThreadingHTTPServer(('127.0.0.1', port), Handler)
    print(f'Review: http://127.0.0.1:{port}', flush=True)
    server.serve_forever()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--port', type=int, default=8767)
    parser.add_argument('--feedback-directory', type=Path,
                        help='Separate feedback destination for isolated review UI validation.')
    args = parser.parse_args()
    serve(args.root, args.port, args.feedback_directory)
