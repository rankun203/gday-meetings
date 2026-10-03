#!/usr/bin/env python3
"""Convert saved transcript arrays to JSONL. Dry run unless --apply is supplied."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid


class MigrationError(ValueError):
    pass


def rows_from_json(source):
    rows = json.loads(source)
    if not isinstance(rows, list):
        raise MigrationError('Expected a saved segment array.')
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get('text'), str):
            raise MigrationError('Invalid saved segment.')
        for field in ('start', 'end'):
            value = row.get(field)
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
                raise MigrationError('Invalid segment time.')
        if row['start'] < 0 or row['end'] < row['start']:
            raise MigrationError('Invalid segment time range.')
        if not isinstance(row.get('speaker'), str):
            raise MigrationError('Missing speaker label.')
        for field in ('id', 'speakerID', 'session', 'personID'):
            if field == 'id' or row.get(field) is not None:
                try:
                    uuid.UUID(row[field])
                except (ValueError, TypeError, KeyError, AttributeError) as error:
                    raise MigrationError('Invalid segment identity.') from error
    return rows


def live_is_empty(folder):
    """Only accept empty current arrays when every saved live snapshot is empty."""
    for path in folder.glob('live-transcript*'):
        if path.name == 'live-transcript.json':
            value = json.loads(path.read_bytes())
            if any(value.get(key) for key in ('phrases', 'effectivePhrases', 'rawSpeakerPhrases', 'overrides', 'savedSegments')):
                return False
        elif path.name not in ('live-transcript-word-speakers.json', 'live-transcript-events.saved.jsonl'):
            # Unknown projection or journal needs explicit review, not guessed replay.
            return False
    return True


def plan(root):
    root = root.resolve(strict=True)
    changes = []
    for folder in sorted((root / 'meetings').iterdir()):
        if folder.is_symlink():
            raise MigrationError('Meeting symlinks require manual review.')
        if not folder.is_dir():
            continue
        old, new = folder / 'transcript.json', folder / 'transcript.jsonl'
        if old.is_symlink() or new.is_symlink():
            raise MigrationError('Transcript symlinks require manual review.')
        if old.exists() and (folder / 'transcript-checkpoint.json').exists():
            raise MigrationError('Legacy array and canonical checkpoint coexist. Review the versions before migration.')
        if not old.exists():
            content = folder / 'content.json'
            if not new.exists() and content.exists() and json.loads(content.read_bytes()).get('transcript'):
                raise MigrationError('Embedded legacy transcript needs review before migration.')
            if not new.exists() and any(folder.glob('live-transcript*')):
                raise MigrationError('Live-only data needs recovery with the previous app before migration.')
            continue
        source = old.read_bytes()
        rows = rows_from_json(source)
        if not rows and not new.exists() and not live_is_empty(folder):
            raise MigrationError('An empty transcript has unresolved live data. Review it with the previous app.')
        if new.exists():
            existing = [json.loads(line) for line in new.read_bytes().splitlines() if line.strip()]
            if existing != rows:
                raise MigrationError('Existing JSONL differs from the saved array. Resolve the conflict first.')
        changes.append((old, new, source, rows))
    return changes


def inventory(root):
    result = {}
    for path in sorted(root.rglob('*')):
        relative = str(path.relative_to(root))
        if path.is_symlink():
            raise MigrationError('Library symlinks require manual review before backup.')
        if path.is_file():
            digest = hashlib.sha256()
            with path.open('rb') as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(block)
            result[relative] = digest.hexdigest()
    return result


def require_stopped():
    processes = subprocess.check_output(['ps', '-axo', 'comm='], text=True)
    if any(Path(line.strip()).name == 'GdayMeetings' for line in processes.splitlines()):
        raise MigrationError('Quit all Gday Meetings app copies before applying migration.')


def publish(path, payload):
    fd, name = tempfile.mkstemp(prefix='.transcript-migration-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        Path(name).unlink(missing_ok=True)


def verify_destination(path, rows):
    if path.is_symlink():
        raise MigrationError('Transcript destination became a symlink. Migration stopped.')
    if path.exists():
        existing = [json.loads(line) for line in path.read_bytes().splitlines() if line.strip()]
        if existing != rows:
            raise MigrationError('JSONL changed after planning. Its backup was kept; migration stopped.')


def migrate(root, backup, changes):
    root, backup = root.resolve(strict=True), backup.resolve()
    if backup.exists() or backup == root or root in backup.parents or backup in root.parents:
        raise MigrationError('Backup must be a new directory outside the library.')
    require_stopped()
    before = inventory(root)
    shutil.copytree(root, backup)
    if inventory(backup) != before or inventory(root) != before:
        raise MigrationError('Library changed during backup or backup verification failed. No transcripts changed.')
    require_stopped()
    for old, new, source, rows in changes:
        verify_destination(new, rows)
        if old.read_bytes() != source:
            raise MigrationError('Transcript changed after planning. No transcripts changed.')
    expected = dict(before)
    for old, new, source, rows in changes:
        require_stopped()
        verify_destination(new, rows)
        if old.read_bytes() != source:
            raise MigrationError('Transcript changed during migration. Originals remain in the backup.')
        payload = b''.join(json.dumps(row, ensure_ascii=False, separators=(',', ':'), allow_nan=False).encode('utf-8') + b'\n' for row in rows)
        publish(new, payload)
        if [json.loads(line) for line in new.read_bytes().splitlines()] != rows:
            raise MigrationError('Published segment verification failed. Originals remain in the backup.')
        old.unlink()
        del expected[str(old.relative_to(root))]
        expected[str(new.relative_to(root))] = hashlib.sha256(payload).hexdigest()
    if inventory(root) != expected:
        raise MigrationError('Unexpected library changes detected. Keep the backup and review before reopening.')
    return sum(len(rows) for _, _, _, rows in changes)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('library', type=Path)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--backup', type=Path, help='New external directory, required with --apply')
    args = parser.parse_args()
    root = args.library.resolve(strict=True)
    if not (root / 'meetings').is_dir():
        parser.error('Expected a library containing meetings/.')
    try:
        changes = plan(root)
        print(f'{len(changes)} saved transcripts; {sum(len(rows) for _, _, _, rows in changes)} segments ready to convert.')
        if not args.apply:
            print('Dry run only. No files changed.')
            return
        if not args.backup:
            parser.error('--apply requires --backup.')
        if not changes:
            print('No migration needed. No files changed.')
            return
        count = migrate(root, args.backup, changes)
        print(f'Converted and verified {len(changes)} transcripts and {count} segments. Full backup: {args.backup.resolve()}')
        print('Revisions, legacy live artifacts, audio, metadata, and other files are unchanged.')
    except (MigrationError, json.JSONDecodeError) as error:
        parser.exit(1, f'Migration stopped: {error}\n')


if __name__ == '__main__':
    main()
