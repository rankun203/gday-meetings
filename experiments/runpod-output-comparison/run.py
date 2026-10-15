"""Isolated client for the existing worker API; never adopts results into a library."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
from urllib.parse import quote, urlencode, urljoin, urlsplit


class Failure(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Failure(message)


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(path, value):
    temporary = path.with_suffix(path.suffix + '.tmp')
    with temporary.open('w', encoding='utf-8') as stream:
        os.chmod(temporary, 0o600)
        json.dump(value, stream, indent=2)
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def read(path):
    return json.loads(path.read_text())


def endpoint(value):
    parts = urlsplit(value)
    require(parts.scheme == 'https' and parts.hostname and not parts.username
            and not parts.password and not parts.query and not parts.fragment,
            'Expected a configured HTTPS endpoint without credentials or query.')
    return value.rstrip('/')


def origin(value):
    parts = urlsplit(value)
    return parts.scheme, parts.hostname, parts.port or 443


def provider(settings, kind, selected=None):
    matches = [p for p in settings['serviceProviders'] if p['kind'] == kind
               and (selected is None or p['id'] == selected)]
    require(len(matches) == 1, 'Choose exactly one configured provider of each required kind.')
    p = matches[0]
    endpoint(p['endpoint'])
    needed = {'transcription', 'diarization'} if kind == 'runpod' else {'fileTransfer'}
    require(needed <= set(p.get('enabledCapabilities', [])), 'Required provider capabilities are disabled.')
    if kind == 'runpod':
        require(urlsplit(p['endpoint']).path.rstrip('/').split('/')[-1]
                not in {'run', 'runsync', 'health', 'status', 'cancel'}, 'Use the RunPod base endpoint.')
    return p


def credential(p):
    """Read existing destination-bound Keychain items; never migrate, set, or delete."""
    identity = hashlib.sha256((p['kind'] + '\n' + p['endpoint']).encode()).hexdigest()
    account = 'provider-' + p['id'].upper() + '-' + identity
    for service in ('com.gdaymeetings.macos', 'app.gday.meetings.swift'):
        result = subprocess.run(['/usr/bin/security', 'find-generic-password', '-s', service,
                                 '-a', account, '-w'], capture_output=True, text=True)
        if result.returncode == 0:
            require(bool(result.stdout.strip()), 'Configured credential is empty.')
            return result.stdout.rstrip('\n')
        require(result.returncode == 44, 'Keychain access failed; no request was sent.')
    raise Failure('Configured Keychain credential was not found.')


def request(method, url, key=None, **kwargs):
    import httpx
    headers = kwargs.pop('headers', {})
    if key:
        headers['Authorization'] = 'Bearer ' + key
    try:
        response = httpx.request(method, url, headers=headers, follow_redirects=False,
                                 timeout=httpx.Timeout(900, connect=30), **kwargs)
        require(200 <= response.status_code < 300,
                'Provider rejected the request (HTTP ' + str(response.status_code) + ').')
        return response.json()
    except Failure:
        raise
    except Exception:
        # URLs may carry signed capabilities; never print transport exceptions or bodies.
        raise Failure('Provider request failed; inspect private state before retrying.') from None


def validated_upload(response, base, expected_bytes):
    resolved = urljoin(endpoint(base) + '/', response['url'])
    parts = urlsplit(resolved)
    require(origin(resolved) == origin(base) and not parts.username
            and not parts.password and not parts.fragment and Path(parts.path).suffix,
            'Filedrop returned an invalid download URL.')
    require(response['size'] == expected_bytes and response['expires_in_secs'] > 0,
            'Filedrop did not confirm a complete, unexpired upload.')
    return resolved, time.time() + response['expires_in_secs']


def output_metrics(response):
    tracks = response.get('output', {}).get('tracks', {})
    require(isinstance(tracks, dict) and tracks, 'Completed job returned no audio tracks.')
    metrics = {}
    for name, track in tracks.items():
        segments = track.get('segments', [])
        words = [w for segment in segments for w in segment.get('words', [])]
        metrics[name] = {
            'segments': len(segments), 'labelled_segments': sum(bool(s.get('speaker')) for s in segments),
            'words': len(words), 'labelled_words': sum(bool(w.get('speaker')) for w in words),
        }
    return metrics


def payload(tracks, language):
    return {'input': {'tracks': [{'audio_url': t['url'], 'track_name': t['track'],
                                  'source_type': 'mic' if t['source'] == 'microphone' else 'system_mix'}
                                 for t in tracks], 'language': language, 'diarize': True}}


def prepare(args, directory):
    require(not (directory / 'state.json').exists(), 'This output already contains a prepared run.')
    settings = read(Path(args.settings))
    providers = {kind: provider(settings, kind, getattr(args, kind)) for kind in ('runpod', 'filedrop')}
    meeting = Path(args.meeting).resolve(strict=True)
    metadata = read(meeting / 'metadata.json')
    filenames = metadata['audioFiles']
    require(isinstance(filenames, list) and len(filenames) == 2, 'Expected the two saved audio tracks.')
    tracks = []
    for index, filename in enumerate(filenames):
        require(isinstance(filename, str) and Path(filename).name == filename, 'Invalid saved audio filename.')
        original = (meeting / filename).resolve(strict=True)
        require(original.parent == meeting, 'Saved audio must reside inside the meeting directory.')
        source = original.stem
        require(source in {'microphone', 'system'}, 'Expected microphone and system audio tracks.')
        require(original.is_file(), 'Audio input must be a file.')
        target = directory / ('track' + str(index) + original.suffix.lower())
        require(original != target, 'Input and copied audio paths must differ.')
        before = digest(original)
        shutil.copyfile(original, target)
        os.chmod(target, 0o600)
        require(before == digest(target) == digest(original), 'Audio changed while copying.')
        tracks.append({'track': 'track' + str(index), 'source': source, 'file': target.name,
                       'sha256': before, 'bytes': target.stat().st_size})
    require(tracks and len({t['source'] for t in tracks}) == len(tracks), 'Provide unique audio sources.')
    state = {'version': 1, 'phase': 'prepared', 'tracks': tracks, 'language': args.language,
             'providers': {kind: {k: p[k] for k in ('id', 'kind', 'endpoint')}
                           for kind, p in providers.items()}}
    save(directory / 'state.json', state)
    print('Prepared copies and hashes. No credentials read or network requests sent.')


def submit(directory):
    path = directory / 'state.json'
    state = read(path)
    require(state['phase'] == 'prepared', 'Submission already attempted; do not submit another job.')
    runpod, transfer = (state['providers'][k] for k in ('runpod', 'filedrop'))
    runpod_key, transfer_key = credential(runpod), credential(transfer)
    limits = request('GET', endpoint(transfer['endpoint']) + '/info')
    state['phase'] = 'uploading'
    save(path, state)
    for track in state['tracks']:
        audio = directory / track['file']
        require(audio.parent == directory and digest(audio) == track['sha256'], 'Copied audio changed.')
        require(0 < track['bytes'] <= limits['max_file_size_bytes'], 'Audio exceeds upload limits.')
        require(audio.suffix[1:] in [s.lower() for s in limits['allowed_extensions']], 'Audio format is not accepted.')
        upload_url = endpoint(transfer['endpoint']) + '/upload?' + urlencode({'filename': audio.name})
        with audio.open('rb') as stream:
            response = request('POST', upload_url, transfer_key, content=stream,
                               headers={'Content-Type': 'application/octet-stream', 'Content-Length': str(track['bytes'])})
        resolved, expiry = validated_upload(response, transfer['endpoint'], track['bytes'])
        track.update(url=resolved, expires_at=expiry)
        save(path, state)
    body = payload(state['tracks'], state['language'])
    save(directory / 'request.json', body)
    # Persist intent before the non-idempotent request. An ambiguous response must never trigger resubmission.
    state['phase'] = 'submission_started'
    save(path, state)
    response = request('POST', endpoint(runpod['endpoint']) + '/run', runpod_key, json=body)
    job_id = response.get('id')
    require(isinstance(job_id, str) and job_id and '/' not in job_id, 'No valid job ID returned; inspect endpoint history.')
    state.update(phase='submitted', job_id=job_id, submitted_at=time.time())
    save(path, state)
    print('Submitted one job; its ID is saved privately. Poll to collect the result.')


def poll(directory):
    path = directory / 'state.json'
    state = read(path)
    require(state['phase'] in {'submitted', 'polling', 'completed', 'failed'}, 'No saved remote job to poll.')
    if state['phase'] in {'completed', 'failed'}:
        print('Job already finished; saved output is unchanged.')
        return
    p = state['providers']['runpod']
    key = credential(p)
    job_id = state['job_id']
    require(isinstance(job_id, str) and job_id and '/' not in job_id, 'Invalid saved job ID.')
    response = request('GET', endpoint(p['endpoint']) + '/status/' + quote(job_id, safe=''), key)
    save(directory / 'raw-response.json', response)
    status = response.get('status')
    require(status in {'IN_QUEUE', 'IN_PROGRESS', 'COMPLETED', 'FAILED', 'CANCELLED', 'TIMED_OUT'}, 'Unrecognized job status.')
    state['phase'] = 'completed' if status == 'COMPLETED' else 'failed' if status in {'FAILED', 'CANCELLED', 'TIMED_OUT'} else 'polling'
    state['last_status'] = status
    save(path, state)
    print('Job status: ' + status + '. Raw response saved privately.')
    if status == 'COMPLETED':
        metrics = output_metrics(response)
        save(directory / 'output-metrics.json', metrics)
        require(set(metrics) == {t['track'] for t in state['tracks']}, 'Completed output has unexpected audio tracks.')
        require(any(m['labelled_words'] or m['labelled_segments'] for m in metrics.values()),
                'Completed output contains no speaker labels; it cannot support this comparison.')
        print(json.dumps(metrics, sort_keys=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'submit', 'poll'])
    parser.add_argument('--output', required=True)
    parser.add_argument('--settings')
    parser.add_argument('--runpod')
    parser.add_argument('--filedrop')
    parser.add_argument('--meeting')
    parser.add_argument('--language', default='en')
    args = parser.parse_args()
    os.umask(0o077)
    directory = Path(args.output).resolve()
    require('.local' in directory.parts or str(directory).startswith('/private/tmp/'), 'Use ignored .local or private temporary storage.')
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    if args.action == 'prepare':
        require(args.settings is not None and args.meeting is not None, 'Prepare requires --settings and --meeting.')
        prepare(args, directory)
    elif args.action == 'submit':
        submit(directory)
    else:
        poll(directory)


if __name__ == '__main__':
    try:
        main()
    except Failure as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
    except Exception:
        print('Operation failed; inspect private state. No automatic submission retry.', file=sys.stderr)
        sys.exit(1)
