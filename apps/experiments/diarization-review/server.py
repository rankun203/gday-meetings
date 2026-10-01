"""Serve a blind, local listening review. All review data stays under root tmp/."""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
import os
from pathlib import Path
import re
import sys
import tempfile
import threading
from urllib.parse import urlsplit
import uuid

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'experiments/diarization-benchmark'))
from build_review import export_review
from score_review import score

MAX_BODY = 2 * 1024 * 1024
IDENTIFIER = re.compile(r'[A-Za-z0-9_-]{1,80}\Z')
SPEAKER = re.compile(r'[A-Za-z0-9 _-]{1,40}\Z')


class ReviewError(Exception):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


def bounded(path, root):
    resolved = path.resolve()
    if not resolved.is_relative_to(root.resolve()):
        raise ReviewError('The requested file is outside the review folder.', 403)
    return resolved


def generated(path):
    return bounded(path, ROOT / 'tmp')


def finite(value):
    return type(value) in (int, float) and math.isfinite(value)


def regions(value, duration, speakers=False):
    if not isinstance(value, list) or len(value) > 10000:
        raise ReviewError('Use a list of at most 10,000 ranges.')
    clean = []
    for row in value:
        if not isinstance(row, dict):
            raise ReviewError('Each range needs a start and end time.')
        start, end = row.get('start'), row.get('end')
        if not finite(start) or not finite(end) or not 0 <= start < end <= duration:
            raise ReviewError('Range times must be inside the clip, with the end after the start.')
        item = dict(start=start, end=end)
        if speakers:
            speaker = row.get('speaker')
            if not isinstance(speaker, str) or not SPEAKER.fullmatch(speaker):
                raise ReviewError('Use an anonymous speaker label with letters, numbers, spaces, or hyphens.')
            item['speaker'] = speaker
        clean.append(item)
    clean.sort(key=lambda row: (row['start'], row['end']))
    if not speakers and any(a['end'] > b['start'] for a, b in zip(clean, clean[1:])):
        raise ReviewError('Reviewed or uncertain ranges must not overlap each other.')
    return clean


class Store:
    def __init__(self, directory):
        self.directory = generated(Path(directory))
        self.lock = threading.RLock()

    def sample(self, name):
        if not IDENTIFIER.fullmatch(name):
            raise ReviewError('Sample not found.', 404)
        path = bounded(self.directory / name, self.directory)
        if not path.is_dir():
            raise ReviewError('Sample not found.', 404)
        return path

    def annotation(self, name):
        sample = self.sample(name)
        return bounded(sample / 'blind/annotations.json', sample)

    @contextmanager
    def transaction(self):
        with self.lock:
            path = bounded(self.directory / '.review.lock', self.directory)
            with path.open('a') as handle:
                fcntl.flock(handle, fcntl.LOCK_EX)
                try:
                    yield
                finally:
                    fcntl.flock(handle, fcntl.LOCK_UN)

    def read(self, name):
        raw = self.annotation(name).read_bytes()
        data = json.loads(raw)
        # Explicit fields prevent private keys and selection categories reaching the browser.
        clips = []
        for clip in data['clips']:
            item = {field: clip[field] for field in ('id', 'audio', 'durationSeconds', 'status')}
            for field in ('intervals', 'reviewedRegions', 'uncertainRegions'):
                keys = ('start', 'end', 'speaker') if field == 'intervals' else ('start', 'end')
                item[field] = [{key: row[key] for key in keys} for row in clip.get(field, [])]
            clips.append(item)
        return dict(revision=hashlib.sha256(raw).hexdigest(), clips=clips,
                    speakerReferences=[{key: row[key] for key in ('speaker', 'clip', 'start', 'end')}
                                       for row in data.get('speakerReferences', [])])

    def listing(self):
        samples = []
        for path in sorted(self.directory.glob('sample-*')):
            if not path.is_dir() or not (path / 'blind/annotations.json').is_file():
                continue
            data = self.read(path.name)
            clips = [{key: clip[key] for key in ('id', 'durationSeconds', 'status')} for clip in data['clips']]
            samples.append(dict(id=path.name, clips=clips, total=len(clips),
                                reviewed=sum(clip['status'] == 'reviewed' for clip in clips)))
        return dict(samples=samples)

    def save(self, name, data, draft=False):
        with self.transaction():
            current = self.read(name)
            if not draft and data.get('revision') != current['revision']:
                raise ReviewError('This sample changed in another window. Reload it before saving.', 409)
            clips = data.get('clips')
            if not isinstance(clips, list) or len(clips) != len(current['clips']):
                raise ReviewError('Save every clip in this sample.')
            clean = []
            for clip, original in zip(clips, current['clips']):
                if not isinstance(clip, dict) or any(clip.get(key) != original[key] for key in ('id', 'audio', 'durationSeconds')):
                    raise ReviewError('Clip IDs, audio files, durations, and order cannot change.')
                if clip.get('status') not in ('unreviewed', 'reviewed'):
                    raise ReviewError('Choose unreviewed or reviewed for the clip status.')
                duration = original['durationSeconds']
                item = {key: original[key] for key in ('id', 'audio', 'durationSeconds')}
                item['status'] = clip['status']
                item['intervals'] = regions(clip.get('intervals'), duration, speakers=True)
                item['reviewedRegions'] = regions(clip.get('reviewedRegions'), duration)
                item['uncertainRegions'] = regions(clip.get('uncertainRegions', []), duration)
                if any(a['start'] < b['end'] and b['start'] < a['end'] for a in item['reviewedRegions'] for b in item['uncertainRegions']):
                    raise ReviewError('Uncertain ranges must be excluded from reviewed coverage.')
                if item['status'] == 'reviewed' and not item['reviewedRegions']:
                    raise ReviewError('A finished clip needs at least one reviewed range.')
                clean.append(item)
            references = data.get('speakerReferences', current['speakerReferences'])
            if not isinstance(references, list) or len(references) > 100:
                raise ReviewError('Use at most 100 speaker references.')
            clean_references = []
            by_id = {clip['id']: clip for clip in clean}
            for reference in references:
                if not isinstance(reference, dict) or reference.get('clip') not in by_id:
                    raise ReviewError('Choose a clip in this sample for the speaker reference.')
                row = regions([reference], by_id[reference['clip']]['durationSeconds'], speakers=True)[0]
                row['clip'] = reference['clip']
                clean_references.append(row)
            path = self.annotation(name)
            original_data = json.loads(path.read_bytes())
            # Preserve existing instructions and schema metadata on disk.
            for original, updated in zip(original_data['clips'], clean):
                original.update(updated)
            original_data['speakerReferences'] = clean_references
            if draft:
                drafts = generated(self.directory / 'drafts')
                drafts.mkdir(mode=0o700, exist_ok=True)
                output = generated(drafts / f'{name}-{uuid.uuid4().hex}.json')
                original_data['draftBaseRevision'] = data.get('revision')
                with output.open('x') as handle:
                    json.dump(original_data, handle, indent=2, allow_nan=False)
                    handle.write('\n')
                    handle.flush()
                    os.fsync(handle.fileno())
                return dict(output=str(output.relative_to(ROOT)))
            backups = bounded(path.parent / 'backups', self.directory)
            backups.mkdir(mode=0o700, exist_ok=True)
            backup = bounded(backups / f'{current["revision"]}-{uuid.uuid4().hex}.json', self.directory)
            with backup.open('xb') as handle:
                handle.write(path.read_bytes())
                handle.flush()
                os.fsync(handle.fileno())
            encoded = (json.dumps(original_data, indent=2, allow_nan=False) + '\n').encode()
            fd, temporary = tempfile.mkstemp(prefix='.annotations-', dir=path.parent)
            try:
                with os.fdopen(fd, 'wb') as handle:
                    handle.write(encoded)
                    handle.flush()
                    os.fsync(handle.fileno())
                os.replace(temporary, path)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
            return self.read(name)

    def audio(self, sample, clip_id):
        data = self.read(sample)
        clip = next((row for row in data['clips'] if row['id'] == clip_id), None)
        if clip is None or not IDENTIFIER.fullmatch(clip_id):
            raise ReviewError('Clip not found.', 404)
        if clip['audio'] != f'{clip_id}.wav':
            raise ReviewError('The clip audio filename is invalid.')
        return bounded(self.sample(sample) / 'blind' / clip['audio'], self.sample(sample) / 'blind')

    def export(self, name):
        with self.transaction():
            if any(clip['status'] != 'reviewed' for clip in self.read(name)['clips']):
                raise ReviewError('Finish every clip in this sample before comparing systems.')
            sample = self.sample(name)
            key_path = bounded(sample / 'private/key.json', sample)
            key = json.loads(key_path.read_bytes())
            if any(not IDENTIFIER.fullmatch(system['id']) for system in key['systems']):
                raise ReviewError('The comparison contains an invalid system ID.')
            for clip in key['clips']:
                self.audio(name, clip['id'])
            output = generated(self.directory / 'exports' / f'{name}-{uuid.uuid4().hex}')
            gold = export_review(sample, output)
            systems = {system['id']: json.loads((output / f'{system["id"]}.json').read_text())['intervals'] for system in key['systems']}
            result = score(gold, systems)
            local_index = 0
            result['systemLabels'] = {}
            for system in key['systems']:
                if system.get('role') == 'saved_reference_not_gold':
                    label = 'Saved Server'
                else:
                    local_index += 1
                    label = f'Local Model {local_index}'
                result['systemLabels'][system['id']] = label
            result['gold_sha256'] = hashlib.sha256((output / 'gold.json').read_bytes()).hexdigest()
            result['system_sha256'] = {name: hashlib.sha256((output / f'{name}.json').read_bytes()).hexdigest() for name in systems}
            (output / 'scores.json').write_text(json.dumps(result, indent=2) + '\n')
            return dict(output=str(output.relative_to(ROOT)), results=result)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Clip requests need not appear in terminal logs.

    def send_headers(self, status, content_type, length, extra=None):
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(length))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; media-src 'self' blob:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()

    def respond(self, value, status=200):
        data = json.dumps(value, allow_nan=False).encode()
        self.send_headers(status, 'application/json; charset=utf-8', len(data))
        self.wfile.write(data)

    def validate_request(self):
        port = self.server.server_address[1]
        hosts = {f'127.0.0.1:{port}', f'localhost:{port}'}
        if self.headers.get('Host') not in hosts:
            raise ReviewError('Open this app using its localhost URL.', 403)
        # A link from another page may open the public shell. Audio and review
        # endpoints still require a same-origin request from that shell.
        if (self.command == 'GET' and urlsplit(self.path).path in ('/', '/index.html')
                and self.headers.get('Sec-Fetch-Dest') == 'document'):
            return
        origin = self.headers.get('Origin')
        if origin is not None and origin not in {f'http://{host}' for host in hosts}:
            raise ReviewError('Requests must come from this review app.', 403)
        if self.headers.get('Sec-Fetch-Site') not in (None, 'same-origin', 'none'):
            raise ReviewError('Requests must come from this review app.', 403)

    def body(self):
        if self.headers.get('Transfer-Encoding') or self.headers.get('Content-Type', '').split(';')[0] != 'application/json':
            raise ReviewError('Send the review as JSON.')
        try:
            length = int(self.headers.get('Content-Length', '0'))
        except ValueError:
            raise ReviewError('The request length is invalid.')
        if not 0 < length <= MAX_BODY:
            raise ReviewError('The review request must be smaller than 2 MiB.', 413)
        value = json.loads(self.rfile.read(length))
        if not isinstance(value, dict):
            raise ReviewError('Send a JSON object.')
        return value

    def handle_request(self):
        try:
            self.validate_request()
            path = urlsplit(self.path).path
            parts = path.strip('/').split('/')
            store = self.server.store
            if self.command == 'GET' and path == '/api/samples':
                return self.respond(store.listing())
            if len(parts) == 3 and parts[:2] == ['api', 'samples']:
                if self.command == 'GET':
                    return self.respond(store.read(parts[2]))
                if self.command == 'PUT':
                    return self.respond(store.save(parts[2], self.body()))
            if self.command == 'POST' and len(parts) == 3 and parts[:2] == ['api', 'export']:
                self.body()
                return self.respond(store.export(parts[2]))
            if self.command == 'POST' and len(parts) == 3 and parts[:2] == ['api', 'drafts']:
                return self.respond(store.save(parts[2], self.body(), draft=True))
            if self.command == 'GET' and len(parts) == 4 and parts[:2] == ['api', 'audio']:
                return self.send_audio(store.audio(parts[2], parts[3]))
            static = {'/': ('index.html', 'text/html'), '/index.html': ('index.html', 'text/html'),
                      '/app.js': ('app.js', 'text/javascript'), '/styles.css': ('styles.css', 'text/css')}
            if self.command == 'GET' and path in static:
                filename, content_type = static[path]
                data = (Path(__file__).parent / 'static' / filename).read_bytes()
                self.send_headers(200, content_type + '; charset=utf-8', len(data))
                return self.wfile.write(data)
            raise ReviewError('Page not found.', 404)
        except ReviewError as error:
            self.respond(dict(error=str(error)), error.status)
        except (json.JSONDecodeError, KeyError, TypeError, ValueError):
            self.respond(dict(error='The review data is invalid. Check its format and try again.'), 400)
        except FileNotFoundError:
            self.respond(dict(error='The requested review file was not found.'), 404)
        except OSError:
            self.respond(dict(error='Could not read or save this review. Check folder permissions and try again.'), 500)

    def send_audio(self, path):
        with path.open('rb') as handle:
            size = os.fstat(handle.fileno()).st_size
            start, end, status = 0, size - 1, 200
            extra = {'Accept-Ranges': 'bytes'}
            requested = self.headers.get('Range')
            if requested:
                match = re.fullmatch(r'bytes=(\d*)-(\d*)', requested)
                if not match or not any(match.groups()):
                    raise ReviewError('Use one byte range for audio playback.', 416)
                a, b = match.groups()
                if a:
                    start, end = int(a), min(int(b), size - 1) if b else size - 1
                else:
                    start = max(0, size - int(b))
                if start > end or start >= size:
                    self.send_headers(416, 'audio/wav', 0, {'Content-Range': f'bytes */{size}'})
                    return
                status = 206
                extra['Content-Range'] = f'bytes {start}-{end}/{size}'
            self.send_headers(status, 'audio/wav', end - start + 1, extra)
            handle.seek(start)
            remaining = end - start + 1
            while remaining:
                data = handle.read(min(65536, remaining))
                if not data:
                    break
                self.wfile.write(data)
                remaining -= len(data)

    do_GET = handle_request
    do_PUT = handle_request
    do_POST = handle_request


def make_server(directory, port=8766):
    server = ThreadingHTTPServer(('127.0.0.1', port), Handler)
    server.store = Store(directory)
    return server


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--review-dir', type=Path, default=ROOT / 'tmp/diarization-evaluation/review')
    parser.add_argument('--port', type=int, default=8766)
    args = parser.parse_args()
    server = make_server(args.review_dir, args.port)
    print(f'Listening review: http://127.0.0.1:{server.server_address[1]}', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
