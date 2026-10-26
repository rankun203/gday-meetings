"""Create a verified, independent snapshot for the voice clustering experiment.

Run with uv run --no-project python; private paths are supplied through CLI flags.
"""
from __future__ import annotations
import argparse
from contextlib import nullcontext
import ctypes
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import sys


def read(path):
    return json.loads(path.read_bytes())


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def stable_json(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'))


def snapshot(source: Path, output: Path, count: int = 20):
    source = source.expanduser().resolve()
    output = output.resolve()
    if output.exists() or source == output or source in output.parents or output in source.parents:
        raise ValueError('Use a new destination outside the source library.')
    observed = {}
    inventories = {}
    clone = None
    if sys.platform == 'darwin':
        clone = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True).clonefile
        clone.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]

    def observe(path):
        if path.is_symlink():
            raise ValueError('Source contains a symbolic link.')
        stat = path.stat()
        value = (stat.st_ino, stat.st_size, stat.st_mtime_ns, digest(path))
        if path in observed and observed[path] != value:
            raise RuntimeError('Source changed during capture.')
        observed[path] = value
        return value

    def load(path):
        observe(path)
        return read(path)

    def inventory(path):
        entries = sorted(path.iterdir()) if path.exists() else []
        inventories[path] = [p.name for p in entries]
        return entries

    def copy(path, target):
        if path.is_symlink():
            raise ValueError('Source contains a symbolic link.')
        if path.is_dir():
            for child in inventory(path):
                if child.name in {'.lock', 'jobs', 'undo', 'providers', '.document-transaction'} or child.name.startswith('.index'):
                    continue
                copy(child, target / child.name)
            return
        before = observe(path)
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if clone is None or clone(os.fsencode(path), os.fsencode(target), 0):
            shutil.copy2(path, target)
        if target.stat().st_ino == before[0] or digest(target) != before[3]:
            raise RuntimeError('Snapshot is not an independent, exact copy.')

    pending = [source / '.document-transaction', source / '.meeting-save.json',
               source / 'voice-library/transaction.json']
    lock_path = source / 'voice-library/.lock'
    with lock_path.open('rb') if lock_path.exists() else nullcontext() as lock:
        if lock:
            fcntl.flock(lock, fcntl.LOCK_SH)
        if any(p.exists() for p in pending):
            raise RuntimeError('A source transaction is pending; retry later.')
        candidates = []
        excluded = []
        for folder in inventory(source / 'meetings'):
            path = folder / 'metadata.json'
            if not path.exists():
                continue
            metadata = load(path)
            checkpoint = folder / 'transcript-checkpoint.json'
            reason = None
            if (folder / 'recording-finalization-recovery.json').exists():
                reason = 'incomplete_finalization'
            elif checkpoint.exists() and not load(checkpoint).get('finished', False):
                reason = 'unfinished_capture'
            elif metadata.get('duration', 0) <= 0 or not metadata.get('audioFiles'):
                reason = 'missing_completed_audio'
            if reason:
                excluded.append({'meeting_id': metadata['id'], 'reason': reason})
            else:
                candidates.append((metadata.get('createdAt', 0), folder, metadata))
        selected = sorted(candidates, key=lambda x: (x[0], x[2]['id']), reverse=True)[:count]
        if len(selected) != count:
            raise RuntimeError(f'Found only {len(selected)} completed meetings.')
        selected.reverse()
        pending.extend(folder / '.document-transaction' for _, folder, _ in selected)
        if any(p.exists() for p in pending):
            raise RuntimeError('A source transaction is pending; retry later.')
        meetings = []
        for order, (_, folder, metadata) in enumerate(selected):
            copy(folder, output / 'library/meetings' / folder.name)
            content = load(folder / 'content.json') if (folder / 'content.json').exists() else {}
            meetings.append({'id': metadata['id'], 'meeting_order': order, 'folder': folder.name,
                             'metadata': metadata, 'speakers': content.get('speakers', [])})
        by_meeting = {m['id']: m for m in meetings}
        examples = []
        for path in inventory(source / 'voice-library/examples'):
            # Read every metadata record to avoid any per-person or sample cap.
            example = load(path)
            if example.get('meetingID') not in by_meeting:
                continue
            copy(path, output / 'library/voice-library/examples' / path.name)
            representation = source / 'voice-library/representations' / path.name
            if representation.exists():
                copy(representation, output / 'library/voice-library/representations' / path.name)
                example['embeddings'] = load(representation).get('embeddings', [])
            examples.append(example)
        decisions = []
        for path in inventory(source / 'voice-library/decisions'):
            decision = load(path)
            if decision.get('meetingID') in by_meeting:
                copy(path, output / 'library/voice-library/decisions' / path.name)
                decisions.append(decision)
        people = []
        person_ids = {e[k] for e in examples for k in ('personID', 'namedPersonID', 'suggestedPersonID') if e.get(k)}
        person_ids.update(d['personID'] for d in decisions if d.get('personID'))
        for path in inventory(source / 'people'):
            if path.suffix != '.json':
                continue
            person = load(path)
            references = [v for v in person.get('voiceSamples', []) if v.get('meetingID') in by_meeting]
            if person.get('id') in person_ids or references:
                person['voiceSamples'] = references
                people.append(person)
                target = output / 'library/people' / path.name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(json.dumps(person))
        settings = load(source / 'settings.json')
        for key in ('autoTranscribe', 'autoExtractTodos', 'automaticVoiceProcessing', 'recognizeSpeakers',
                    'autoSummarize', 'autoDiarize', 'autoTranscribeEvenWithLiveTranscript'):
            settings[key] = False
        settings['serviceProviders'] = []
        for key in list(settings):
            if key.endswith('ProviderID'):
                settings.pop(key)
        (output / 'library/settings.json').write_text(json.dumps(settings))
        if any(p.exists() for p in pending):
            raise RuntimeError('A transaction appeared during capture.')
        for path, names in inventories.items():
            if sorted(p.name for p in path.iterdir()) != names:
                raise RuntimeError('Source directory changed during capture.')
        for path, before in observed.items():
            stat = path.stat()
            if (stat.st_ino, stat.st_size, stat.st_mtime_ns, digest(path)) != before:
                raise RuntimeError('Source changed during capture; discard destination.')
    rows = []
    invalid = 0
    for example in examples:
        meeting = by_meeting[example['meetingID']]
        speaker = next((s for s in meeting['speakers'] if s['id'] == example.get('speakerID')), {})
        spans = example.get('spans') or ([{'start': example['start'], 'end': example['end']}]
                    if example.get('start') is not None and example.get('end') is not None else [])
        audio = output / 'library/meetings' / meeting['folder'] / example.get('audioFile', '')
        physical = [example['meetingID'], example.get('audioFile'), example.get('audioRevision'), spans]
        density_key = hashlib.sha256(stable_json(physical).encode()).hexdigest()
        confirmed = example.get('review') == 'confirmed' and bool(example.get('personID'))
        active = confirmed and not example.get('excluded') and not example.get('manuallyCleared')
        typed = example.get('embeddings', [])
        for index, embedding in enumerate(typed):
            values = embedding.get('values', [])
            kind = embedding.get('type', {})
            valid = (len(values) == kind.get('dimension') and bool(values)
                     and all(isinstance(v, (int, float)) and math.isfinite(v) for v in values)
                     and sum(v*v for v in values) > 0)
            invalid += not valid
            row = {'id': example['id'] if len(typed) == 1 else f"{example['id']}:{index}",
                   'example_id': example['id'], 'meeting_id': example['meetingID'],
                   'meeting_order': meeting['meeting_order'], 'speaker_id': example.get('speakerID'),
                   'local_speaker': (f"{example['meetingID']}:{example.get('detectedSpeakerResultID')}:{example['detectedSpeakerID']}"
                                     if example.get('detectedSpeakerID') else f"{example['meetingID']}:{example.get('speakerID')}"),
                   'local_label': speaker.get('label'), 'model': stable_json(kind),
                   'embedding': values, 'embedding_type': kind, 'eligible': bool(valid and not example.get('excluded') and not example.get('manuallyCleared')),
                   'person_id': example.get('personID') if confirmed else None,
                   'association_person_id': example.get('personID') or example.get('namedPersonID'),
                   'confirmed': confirmed, 'active_reference': bool(active),
                   'rejected_person_ids': example.get('rejectedPersonIDs', []), 'density_key': density_key,
                   'density_meeting_key': f"{example['meetingID']}:{example.get('speakerID')}",
                   'support_spans': spans, 'duration': sum(s['end']-s['start'] for s in spans),
                   'audio_path': str(audio.relative_to(output)) if audio.is_file() else None,
                   'source': example.get('source'), 'audio_revision': example.get('audioRevision'),
                   'quality': 1.0, 'sample_quality': example.get('sampleQuality'),
                   'origin': example.get('origin'), 'selected_reference': example.get('selectedReference')}
            rows.append(row)
    cached_turns = []
    for meeting in meetings:
        for path in (output / 'library/meetings' / meeting['folder'] / 'voice-analysis').glob('*.json'):
            cache = read(path)
            for turn in cache.get('turnSamples', []):
                cached_turns.append({'meeting_id': meeting['id'], 'cache': path.name, **turn})
    availability = {'meetings': len(meetings), 'stored_examples': len(examples), 'embedding_rows': len(rows),
                    'examples_without_embeddings': sum(not e.get('embeddings') for e in examples),
                    'invalid_embedding_rows': invalid, 'cached_turn_ranges': len(cached_turns),
                    'cached_turns_with_embeddings': sum(bool(t.get('embedding') or t.get('voiceEmbedding') or t.get('embeddings')) for t in cached_turns),
                    'confirmed_rows': sum(r['confirmed'] for r in rows),
                    'eligible_rows': sum(r['eligible'] for r in rows),
                    'audio_available_rows': sum(bool(r['audio_path']) for r in rows)}
    payload = {'schema_version': 1, 'samples': rows, 'examples': examples, 'meetings': meetings,
               'decisions': decisions, 'people': people, 'cached_turns': cached_turns,
               'metadata': {'availability': availability, 'thresholds': {'suggestion': .55, 'automatic': .8, 'minimum_margin': .08},
                            'limitations': ['Stored excerpts cover selected evidence; missing turn embeddings are not recomputed.',
                                            'Human confirmations are partial reference labels.',
                                            'quality=1 is a neutral comparison weight; raw signal metadata is preserved.']}}
    (output / 'input.json').write_text(json.dumps(payload, ensure_ascii=False))
    manifest = {'source': str(source), 'output': str(output), 'source_unchanged': True,
                'selected_meeting_ids': list(by_meeting), 'excluded_meetings': excluded, 'availability': availability,
                'observed_files': {str(p.relative_to(source)): {'inode': v[0], 'size': v[1], 'mtime_ns': v[2], 'sha256': v[3]} for p,v in observed.items()},
                'pending_transaction_paths_checked': [str(p.relative_to(source)) for p in pending],
                'pending_transactions_absent_before_and_after': True,
                'directory_inventories': {str(p.relative_to(source)): names for p, names in inventories.items()},
                'remote_providers_enabled': False, 'automatic_processing_enabled': False,
                'omitted': ['tasks', 'jobs', 'undo', 'indexes', 'provider credentials']}
    (output / 'manifest.json').write_text(json.dumps(manifest))
    return availability


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--count', type=int, default=20)
    args = parser.parse_args()
    existed = args.output.exists()
    try:
        print(json.dumps(snapshot(args.source, args.output, args.count), indent=2))
    except Exception:
        # Remove this attempt's incomplete copy while preserving existing destinations.
        if not existed and args.output.exists():
            shutil.rmtree(args.output)
        raise


if __name__ == '__main__':
    main()
