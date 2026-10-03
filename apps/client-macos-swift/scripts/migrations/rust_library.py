#!/usr/bin/env python3
"""Copy a stopped Rust library into a Swift library; dry run unless --apply."""
import argparse
import datetime as dt
import hashlib
import json
import math
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid

NAMESPACE = uuid.UUID('6f31a7dd-6da8-53ea-b1b6-5c68313a4029')
AUDIO = {'.wav', '.mp3', '.m4a', '.caf', '.flac', '.ogg', '.opus'}
MANIFEST = '.rust-library-import.json'
SCOPE = 'legacy:rust:runpod'


class MigrationError(Exception):
    pass


def identity(kind, key):
    return str(uuid.uuid5(NAMESPACE, kind + ':' + key)).upper()


def encode(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2, allow_nan=False) + '\n').encode()


def read(path, default=None):
    return json.loads(path.read_bytes()) if path.exists() else default


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def inventory(root):
    result = {}
    if root.is_symlink():
        raise MigrationError('Symbolic links require manual review.')
    for path in sorted(root.rglob('*')):
        if path.is_symlink():
            raise MigrationError('Symbolic links require manual review.')
        if path.is_file():
            result[str(path.relative_to(root))] = digest(path)
        elif not path.is_dir():
            raise MigrationError('Unsupported filesystem entry.')
    return result


def source_inventory(root):
    result = {}
    for name in ('recordings', 'people', 'conversations'):
        folder = root / name
        if folder.exists():
            result.update({name + '/' + k: v for k, v in inventory(folder).items()})
    if (root / 'tags.json').exists():
        if (root / 'tags.json').is_symlink():
            raise MigrationError('Symbolic links require manual review.')
        result['tags.json'] = digest(root / 'tags.json')
    return result


def date(value):
    parsed = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
    if parsed.tzinfo is None:
        raise MigrationError('A source date has no time zone.')
    return parsed.timestamp() - 978307200


def base36(identifier):
    value = uuid.UUID(identifier).int
    result = ''
    while value:
        value, remainder = divmod(value, 36)
        result = '0123456789abcdefghijklmnopqrstuvwxyz'[remainder] + result
    return result or '0'


def vector(value):
    if (not isinstance(value, list) or not 0 < len(value) <= 4096
            or not all(type(x) in (int, float) and math.isfinite(x) for x in value)
            or not any(x != 0 for x in value)):
        raise MigrationError('Invalid voice sample; source needs review.')
    return value


def stopped():
    processes = subprocess.check_output(['ps', '-axo', 'comm='], text=True)
    names = {'GdayMeetings', 'gday-meetings-client', 'gday-meetings', 'meeting-notes'}
    for line in processes.splitlines():
        executable = Path(line.strip())
        if executable.name not in names:
            continue
        info = executable.parent.parent / 'Info.plist'
        if info.is_file():
            with info.open('rb') as stream:
                if plistlib.load(stream).get('GdayUIPreview') is True:
                    continue  # UIPreview.makeStore always creates its own temporary library.
        raise MigrationError('Quit the Swift and Rust apps before applying migration.')


def build_plan(source, target, embedding_origin=None):
    if embedding_origin != "runpod":
        raise MigrationError("Confirm legacy RunPod origin with --embedding-origin runpod.")
    if Path(source).is_symlink() or Path(target).is_symlink():
        raise MigrationError('Library roots must not be symbolic links.')
    source, target = Path(source).resolve(), Path(target).resolve()
    if source == target or source in target.parents or target in source.parents:
        raise MigrationError('Source and destination must be separate libraries.')
    if not (source / 'recordings').is_dir() or not target.is_dir():
        raise MigrationError('Choose an existing Rust source and Swift destination.')
    hashes = source_inventory(source)
    baseline = inventory(target)
    previous = read(target / MANIFEST)
    if previous:
        if previous['sourceHashes'] != hashes or previous['source'] != str(source):
            raise MigrationError('The source changed after import; review before importing again.')
        if any(not (target / name).is_file() for name in previous['outputs']):
            raise MigrationError('An imported file is missing; restore it before repeating the import.')
        return {'outputs': {}, 'manifest': previous, 'baseline': baseline, 'sourceHashes': hashes,
                'source': source, 'target': target, 'alreadyImported': True}
    outputs = {}

    def put(path, value):
        key = str(path)
        if key in outputs:
            raise MigrationError('Two source records resolve to the same destination.')
        outputs[key] = value

    def archive(folder, relative):
        for path in sorted(folder.rglob('*')):
            if path.is_file():
                put(relative / path.relative_to(folder), path)

    people_folders = [p for p in sorted((source / 'people').glob('*'))
                      if p.is_dir() and (p / 'profile.json').exists()]
    if any(p.is_dir() and not (p / 'profile.json').exists()
           for p in (source / 'people').glob('*')):
        raise MigrationError('A person folder has no profile.json.')
    people_map = {p.name: identity('person', p.name) for p in people_folders}
    overlapping_names = []
    target_people = [read(p) for p in sorted((target / 'people').glob('*.json'))]
    for folder in people_folders:
        name = ' '.join(read(folder / 'profile.json')['name'].split()).casefold()
        matches = [p['id'] for p in target_people if name and ' '.join(p['name'].split()).casefold() == name]
        if matches:
            overlapping_names.append({'sourcePersonID': folder.name, 'destinationPersonIDs': matches})
    folders = [p for p in sorted((source / 'recordings').iterdir())
               if p.is_dir() and (p / 'metadata.json').exists()]
    # A directory containing data but lacking metadata must not silently disappear.
    if any(p.is_dir() and not (p / 'metadata.json').exists()
           for p in (source / 'recordings').iterdir()):
        raise MigrationError('A recording folder has no metadata.json.')
    meeting_map = {p.name: identity('meeting', p.name) for p in folders}
    existing = {}
    audio_sets = {}
    for p in sorted((target / 'meetings').glob('*/metadata.json')):
        item = read(p)
        existing[item['id']] = p.parent
        keys = item.get('audioFiles', [])
        if keys:
            paths = [p.parent / name for name in keys]
            if any(q.parent != p.parent or not q.is_file() for q in paths):
                raise MigrationError('An existing meeting has an invalid audio reference.')
            key = tuple(sorted(digest(q) for q in paths))
            audio_sets.setdefault(key, []).append(item['id'])
    reused = {}
    for p in folders:
        files = [q for q in p.iterdir() if q.is_file() and q.suffix.lower() in AUDIO]
        if files:
            key = tuple(sorted(hashes[str(q.relative_to(source))] for q in files))
            matches = audio_sets.get(key, [])
            if len(matches) > 1:
                raise MigrationError('The same recording matches multiple destination meetings.')
            if matches:
                meeting_map[p.name] = matches[0]
                reused[p.name] = matches[0]
    if len(set(meeting_map.values())) != len(meeting_map):
        raise MigrationError('Multiple source meetings match the same destination meeting.')
    tags = read(source / 'tags.json', {'tags': []})['tags']
    tag_defs = {t['name']: t for t in tags}
    tag_names = set(tag_defs)
    for p in folders:
        tag_names.update(read(p / 'metadata.json').get('tags', []))
    existing_tags = {}
    tag_visibility_conflicts = []
    for p in sorted((target / 'tags').glob('*.json')):
        t = read(p)
        if t['name'] in existing_tags:
            raise MigrationError('Duplicate destination tag names require review.')
        existing_tags[t['name']] = t['id']
        if t['name'] in tag_defs and t.get('isExcluded', False) != tag_defs[t['name']].get('hidden', False):
            tag_visibility_conflicts.append({'name': t['name'], 'destinationID': t['id'],
                                             'sourceHidden': tag_defs[t['name']].get('hidden', False),
                                             'retainedDestinationExcluded': t.get('isExcluded', False)})
    tag_map = {}
    for name in sorted(tag_names):
        tag_map[name] = existing_tags.get(name, identity('tag', name))
        if name not in existing_tags:
            put(Path('tags') / (tag_map[name] + '.json'), encode({
                'id': tag_map[name], 'name': name, 'color': 'blue',
                'isExcluded': tag_defs.get(name, {}).get('hidden', False)}))
    speakers_by_meeting = {}
    segment_count = omitted_speaker_embeddings = unresolved_person_rows = 0
    unresolved_people = {}
    for folder in folders:
        raw = read(folder / 'metadata.json')
        if raw.get('session_id') != folder.name:
            raise MigrationError('A recording identity does not match its folder.')
        created = date(raw['created_at'])
        mid = meeting_map[folder.name]
        relative = (existing[mid].relative_to(target) if folder.name in reused
                    else Path('meetings') / base36(mid))
        # Keep source artifacts not represented by the Swift schema inspectable.
        for path in sorted(folder.rglob('*')):
            if not path.is_file():
                continue
            rel = path.relative_to(folder)
            is_audio = path.parent == folder and path.suffix.lower() in AUDIO
            if is_audio:
                if folder.name not in reused:
                    put(relative / rel, path)
            else:
                put(relative / 'legacy-rust' / rel, path)
                # Retain relative image/document links in authored Markdown.
                if folder.name not in reused and (len(rel.parts) > 1 or path.suffix.lower() not in {'.json', '.md'}
                                                  or (path.suffix.lower() == '.md' and path.name not in {'metadata.md', 'transcript.md', 'notes.md', 'summary.md'})):
                    put(relative / rel, path)
        if folder.name in reused:
            speakers_by_meeting[mid] = read(existing[mid] / 'content.json', {}).get('speakers', [])
            continue
        transcript = read(folder / 'transcript.json', {'segments': []})
        if not (folder / 'transcript.json').exists() and (folder / 'transcript.md').exists():
            raise MigrationError('A Markdown-only transcript requires a reviewed conversion.')
        raw_tracks = read(folder / 'extraction_raw.json', {}).get('tracks', {})
        speaker_index = transcript.get('speaker_embeddings', {})
        speakers = {}
        rows = []
        for index, row in enumerate(transcript['segments']):
            start, end = row['start'], row['end']
            if not all(type(v) in (int, float) and math.isfinite(v) for v in (start, end)) or start < 0 or end < start:
                raise MigrationError('A transcript segment has invalid times.')
            label, track = row.get('speaker') or 'Speaker', row.get('track') or ''
            info = speaker_index.get(label, {})
            pid = row.get('person_id') or info.get('person_id')
            if pid and pid not in people_map:
                unresolved_person_rows += 1
                unresolved_people.setdefault(pid, set()).add(folder.name)
                pid = None
            key = json.dumps([track, label, pid], ensure_ascii=False)
            if key not in speakers:
                item = {'id': identity('speaker', folder.name + ':' + key), 'label': label,
                        'track': track, 'providerName': 'RunPod (Rust Import)', 'voiceScope': SCOPE,
                        'confirmed': bool(pid)}
                embedding = raw_tracks.get(track, {}).get('speaker_embeddings', {}).get(label, info.get('embedding'))
                if embedding is not None:
                    try:
                        item['embedding'] = vector(embedding)
                    except MigrationError:
                        omitted_speaker_embeddings += 1
                if pid:
                    item['personID'] = people_map[pid]
                confidence = info.get('confidence', row.get('attribution_confidence'))
                if confidence is not None:
                    item['confidence'] = confidence
                speakers[key] = item
            rows.append({'id': identity('segment', folder.name + ':' + str(index)),
                         'start': start, 'end': end, 'speaker': label, 'speakerID': speakers[key]['id'],
                         'text': row['text']})
        notes_path = folder / 'notes.md'
        notes = notes_path.read_text() if notes_path.exists() else raw.get('notes') or ''
        summary_path = folder / 'summary.md'
        summary = summary_path.read_text() if summary_path.exists() else read(folder / 'summary.json', {}).get('content', '')
        todos = [{'id': identity('todo', folder.name + ':' + str(i)),
                  'title': todo.get('full_text') or todo['text'], 'isCompleted': todo['completed']}
                 for i, todo in enumerate(read(folder / 'todos.json', {'items': []})['items'])]
        audio = sorted(p.name for p in folder.iterdir() if p.is_file() and p.suffix.lower() in AUDIO)
        meeting = {'id': mid, 'title': raw.get('name') or 'Untitled Meeting', 'createdAt': created,
                   'duration': raw.get('duration_secs') or 0, 'language': raw.get('language') or 'en',
                   'personIDs': sorted({s['personID'] for s in speakers.values() if 'personID' in s}),
                   'tagIDs': [tag_map[t] for t in raw.get('tags', [])], 'audioFiles': audio,
                   'speakers': list(speakers.values()), 'todos': todos, 'chat': [],
                   'notes': '', 'summary': '', 'transcript': [], 'completedTaskIDs': {},
                   'liveTranscriptAdopted': False}
        metadata = {k: meeting[k] for k in ('id', 'title', 'createdAt', 'duration', 'personIDs', 'tagIDs', 'audioFiles')}
        metadata.update(summary=summary[:240], hasTranscriptionAttempt=False)
        put(relative / 'metadata.json', encode(metadata))
        put(relative / 'content.json', encode(meeting))
        put(relative / 'notes.md', notes.encode())
        put(relative / 'summary.md', summary.encode())
        put(relative / 'transcript.jsonl', b''.join(json.dumps(r, ensure_ascii=False, allow_nan=False).encode() + b'\n' for r in rows))
        speakers_by_meeting[mid] = list(speakers.values())
        segment_count += len(rows)
    sample_count = linked_samples = 0
    for folder in people_folders:
        profile = read(folder / 'profile.json')
        pid = people_map[folder.name]
        samples = []
        for i, sample in enumerate(read(folder / 'embeddings.json', {'samples': []})['samples']):
            embedding = vector(sample['embedding'])
            session = sample['session_id']
            mid = meeting_map.get(session, identity('meeting', session))
            matches = [s for s in speakers_by_meeting.get(mid, [])
                       if s.get('personID') == pid and s.get('embedding') == embedding]
            sid = matches[0]['id'] if len(matches) == 1 else identity('unresolved-sample', folder.name + ':' + str(i))
            linked_samples += len(matches) == 1
            samples.append({'meetingID': mid, 'speakerID': sid, 'scope': SCOPE, 'embedding': embedding})
        person = {'id': pid, 'name': profile['name'], 'notes': profile.get('notes') or '',
                  'email': profile.get('email') or '', 'tagIDs': [], 'voiceSamples': samples}
        put(Path('people') / (pid + '.json'), encode(person))
        archive(folder, Path('rust-import-archive/people') / folder.name)
        sample_count += len(samples)
    for name in ('recordings', 'people'):
        for path in sorted((source / name).glob('*')):
            if path.is_file():
                put(Path('rust-import-archive') / name / path.name, path)
    for name in ('conversations',):
        if (source / name).exists():
            archive(source / name, Path('rust-import-archive') / name)
    if (source / 'tags.json').exists():
        put(Path('rust-import-archive/tags.json'), source / 'tags.json')
    manifest = {'version': 1, 'source': str(source), 'sourceHashes': hashes,
                'meetingIDMap': meeting_map, 'personIDMap': people_map, 'tagIDMap': tag_map,
                'reusedMeetings': reused, 'outputs': sorted(outputs),
                'review': {'unmergedNameOverlaps': overlapping_names,
                           'unresolvedSourcePeople': {k: sorted(v) for k, v in unresolved_people.items()},
                           'tagVisibility': tag_visibility_conflicts},
                'counts': {'sourceMeetings': len(folders), 'newMeetings': len(folders) - len(reused),
                           'reusedMeetings': len(reused), 'people': len(people_map), 'voiceSamples': sample_count,
                           'linkedVoiceSamples': linked_samples, 'newTranscriptSegments': segment_count,
                           'omittedInvalidSpeakerEmbeddings': omitted_speaker_embeddings,
                           'retainedDestinationTagVisibility': len(tag_visibility_conflicts),
                           'unmergedNameOverlaps': len(overlapping_names),
                           'unresolvedSourcePeople': len(unresolved_people),
                           'unresolvedPersonRows': unresolved_person_rows}}
    for name, value in outputs.items():
        if name in baseline:
            expected = digest(value) if isinstance(value, Path) else hashlib.sha256(value).hexdigest()
            if baseline[name] != expected:
                raise MigrationError('An import destination already contains different data.')
    return {'outputs': outputs, 'manifest': manifest, 'baseline': baseline, 'sourceHashes': hashes,
            'source': source, 'target': target, 'alreadyImported': False}


def apply(plan, backup):
    stopped()
    if plan['alreadyImported']:
        return
    source, target = plan['source'], plan['target']
    backup = Path(backup).resolve()
    if backup.exists() or source == backup or source in backup.parents or target == backup or target in backup.parents:
        raise MigrationError('Choose a new backup folder outside both libraries.')
    if source_inventory(source) != plan['sourceHashes'] or inventory(target) != plan['baseline']:
        raise MigrationError('A library changed after planning. Run the command again.')
    shutil.copytree(target, backup)
    if inventory(backup) != plan['baseline']:
        raise MigrationError('Backup verification failed.')
    added = []
    added_directories = []
    with tempfile.TemporaryDirectory(prefix='.rust-import-', dir=target.parent) as temporary:
        stage = Path(temporary)
        for name, value in plan['outputs'].items():
            dest = stage / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            if isinstance(value, Path):
                shutil.copy2(value, dest)
                if digest(dest) != plan['sourceHashes'][str(value.relative_to(source))]:
                    raise MigrationError('A copied source file changed.')
            else:
                dest.write_bytes(value)
            dest.chmod(0o600)
        if source_inventory(source) != plan['sourceHashes'] or inventory(target) != plan['baseline']:
            raise MigrationError('A library changed while staging. Nothing was imported.')
        stopped()
        try:
            # Exclusive hard-link publication never replaces existing user data.
            for name in sorted(plan['outputs']):
                dest = target / name
                if name in plan['baseline']:
                    continue
                missing = []
                parent = dest.parent
                while not parent.exists():
                    missing.append(parent)
                    parent = parent.parent
                for parent in reversed(missing):
                    parent.mkdir(mode=0o700)
                    added_directories.append(parent)
                os.link(stage / name, dest)
                added.append(dest)
            manifest = stage / MANIFEST
            manifest.write_bytes(encode(plan['manifest']))
            manifest.chmod(0o600)
            os.link(manifest, target / MANIFEST)
            added.append(target / MANIFEST)
            expected = dict(plan['baseline'])
            expected.update({name: digest(stage / name) for name in plan['outputs']})
            expected[MANIFEST] = digest(manifest)
            if inventory(target) != expected or source_inventory(source) != plan['sourceHashes']:
                raise MigrationError('Final preservation verification failed.')
        except BaseException:
            for path in reversed(added):
                path.unlink(missing_ok=True)
            for directory in reversed(added_directories):
                try:
                    directory.rmdir()
                except OSError:
                    pass  # Never remove files another writer created.
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('target', type=Path)
    parser.add_argument('--embedding-origin', required=True, choices=['runpod'],
                        help='Confirm that the source voice vectors came from RunPod.')
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--backup', type=Path)
    args = parser.parse_args()
    try:
        plan = build_plan(args.source, args.target, args.embedding_origin)
        print(json.dumps(plan['manifest']['counts'], sort_keys=True))
        if plan['alreadyImported']:
            print('Already imported. Existing edits were preserved.')
        elif args.apply:
            if args.backup is None:
                parser.error('--apply requires --backup pointing to a new external folder')
            apply(plan, args.backup)
            print('Import verified. Source and existing destination files were preserved.')
        else:
            print('Dry run. No files changed.')
    except (MigrationError, OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f'Import stopped: {error}\n')


if __name__ == '__main__':
    main()
