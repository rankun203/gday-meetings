"""Read current copied transcripts and intersect physical excerpt support conservatively.

The canonical JSONL remains current even when its selected source points to an older
immutable analysis artifact. Source artifacts supply audio bindings, never replacement text.
"""
from __future__ import annotations

from collections import Counter, defaultdict
import json
import hashlib
import math
import uuid
from pathlib import Path


def private_path(base, name):
    path = base / name
    resolved = path.resolve()
    if not resolved.is_relative_to(base.resolve()) or path.is_symlink():
        raise ValueError('The copied transcript path is outside its meeting or uses a symbolic link.')
    return path


def read_json(path):
    return json.loads(path.read_text()) if path.is_file() else None


def current_rows(folder):
    path = private_path(folder, 'transcript.jsonl')
    checkpoint = read_json(private_path(folder, 'transcript-checkpoint.json'))
    if checkpoint and checkpoint.get('version') != 2:
        raise ValueError('The transcript checkpoint uses an unsupported format.')
    if not path.exists():
        if checkpoint:
            raise ValueError('The saved transcript is missing; its checkpoint was kept.')
        return [], 'missing'
    data = path.read_bytes()
    unfinished = checkpoint and not checkpoint.get('finished')
    if unfinished:
        count = checkpoint['bytes']
        if not isinstance(count, int) or not 0 <= count <= len(data):
            raise ValueError('The transcript checkpoint has an invalid byte boundary.')
        data = data[:count]
        if data and not data.endswith(b'\n'):
            raise ValueError('The transcript checkpoint ends inside a row.')
    rows = [json.loads(line) for line in data.splitlines()]
    if unfinished:
        if len(rows) != checkpoint['rows']:
            raise ValueError('The transcript checkpoint row count does not match.')
        rows.extend(checkpoint['segments'])
    ids = set()
    for row in rows:
        if not row.get('id') or row['id'] in ids:
            raise ValueError('The transcript has missing or repeated row identities.')
        ids.add(row['id'])
        start, end = row.get('start'), row.get('end')
        if (not isinstance(start, (int, float)) or not isinstance(end, (int, float))
                or not math.isfinite(start) or not math.isfinite(end) or not 0 <= start <= end
                or not isinstance(row.get('text'), str)):
            raise ValueError('The transcript contains an invalid row.')
    return rows, 'checkpoint' if unfinished else 'current'


def normalized_source(value):
    return {'mic': 'microphone', 'microphone': 'microphone', 'sys': 'system',
            'system_mix': 'system', 'system': 'system'}.get((value or '').lower())


def file_source(name):
    stem = Path(name).stem
    if '-compatible-' in stem:
        prefix, suffix = stem.rsplit('-compatible-', 1)
        try:
            if len(suffix) == 36 and str(uuid.UUID(suffix)) == suffix.lower():
                stem = prefix
        except ValueError:
            pass
    return normalized_source(stem) if stem.lower() in ('mic', 'microphone', 'system', 'system_mix') else 'unknown'


def track_index(track):
    if isinstance(track, str) and track.startswith('track') and track[5:].isdigit():
        return int(track[5:])
    return None


def resolve_track(row, speaker, files):
    """Port VoiceSampleTranscript.sourceFile; retain original ordinals of missing files."""
    if row.get('analysisTrackID') is not None:
        index = track_index(row['analysisTrackID'])
        if index is not None:
            return index if index < len(files) else None
    if row.get('source') is None and speaker.get('track', '').startswith('track'):
        index = track_index(speaker['track'])
        if index is not None:
            return index if index < len(files) else None
    source = row.get('source') or normalized_source(speaker.get('track'))
    if source:
        matches = [i for i, name in enumerate(files) if file_source(name) == source]
        if len(matches) == 1:
            return matches[0]
        if len(files) == 1 and file_source(files[0]) == 'unknown':
            return 0
        return None
    return 0 if len(files) == 1 else None


def union_length(intervals):
    end, total = -math.inf, 0.
    for lower, upper in sorted(intervals):
        if upper > end:
            total += upper - max(lower, end)
            end = upper
    return total


def sample_file(sample):
    value = sample.get('audio_file') or sample.get('audioFile') or sample.get('audio_path')
    return Path(value).name if value else None


def original_range(row):
    anchors = row.get('sourceSpans') or []
    if not anchors or ''.join((a.get('separatorBefore') or '') + a['text'] for a in anchors) != row['text']:
        return None
    first = anchors[0]
    end = first['range']['location']
    for anchor in anchors:
        bounds = anchor['range']
        length = len(anchor['text'].encode('utf-16-le')) // 2
        if (anchor['rowID'] != first['rowID'] or anchor.get('separatorBefore')
                or bounds['location'] != end or bounds['length'] != length
                or bounds['location'] < 0 or bounds['location'] > 2**63 - 1 - length):
            return None
        end = bounds['location'] + length
    return first['rowID'], first['range']['location'], end


def supported_identity(row, speakers):
    if row.get('associationUncertain') or row.get('sourcePlaceholder') or not row.get('speakerID'):
        return None
    speaker = speakers.get(row['speakerID'], {})
    return ((speaker.get('voiceReviewOrigin') or {}).get('speakerID', row['speakerID']), speaker.get('personID'))


def protected(row, speakers):
    speaker = speakers.get(row.get('speakerID'), {})
    return (row.get('personID') is not None or speaker.get('passageAssignmentOrigin') is not None
            or (speaker.get('personID') is not None and speaker.get('voiceReviewOrigin') is None
                and speaker.get('manuallyAssigned') is not True))


def allows_person(row, speaker):
    if row.get('associationUncertain') is not True:
        return True
    if not speaker:
        return False
    if speaker.get('manuallyAssigned') is not True:
        origin = speaker.get('voiceReviewOrigin') or {}
        return (speaker.get('independentTurnAttribution') is not True and speaker.get('personID') is not None
                and speaker.get('voiceReviewExampleID') is not None
                and origin.get('transcriptAssociationTier') is None
                and bool(origin) and origin.get('speakerID') != speaker.get('id'))
    through = speaker.get('manualReviewThrough')
    if through is None:
        return True
    limit = through.get(row.get('source'))
    return limit is not None and row['end'] <= limit


def saved_person(row, speakers):
    speaker = speakers.get(row.get('speakerID'), {})
    return speaker.get('personID') if allows_person(row, speaker) else None


def passage_rows(rows, speakers):
    """Port TranscriptPassagePresentation.groups; retain every canonical constituent."""
    groups, identity = [], None
    for row in rows:
        last = groups[-1][-1] if groups else None
        left, right = original_range(last) if last else None, original_range(row)
        next_identity = supported_identity(row, speakers)
        compatible = (identity is None or next_identity is None
                      or (identity[0] == next_identity[0]
                          and (identity[1] is None or next_identity[1] is None or identity[1] == next_identity[1])))
        if (last and not protected(row, speakers) and not protected(last, speakers)
                and all(row.get(key) == last.get(key) for key in ('source', 'session', 'analysisTrackID'))
                and left and right and left[0] == right[0] and left[2] == right[1] and compatible):
            groups[-1].append(row)
            if next_identity and (identity is None or identity[1] is None):
                identity = next_identity
        else:
            groups.append([row])
            identity = next_identity
    output = []
    for group in groups:
        supported = [r for r in group if supported_identity(r, speakers) is not None]
        label = (next((r for r in supported if (speakers.get(r.get('speakerID'), {}).get('voiceReviewOrigin') or {}).get('transcriptAssociationTier') == 'tentative'), None)
                 or next((r for r in supported if saved_person(r, speakers)), None) or (supported or group)[0])
        merged = {**label, 'id': group[0]['id'], 'start': group[0]['start'], 'end': max(r['end'] for r in group),
                  'text': group[0]['text'].lstrip() + ''.join(r['text'] for r in group[1:]),
                  'constituents': group, 'constituent_row_ids': [r['id'] for r in group]}
        identities = [saved_person(r, speakers) for r in group]
        nonnil = {p for p in identities if p is not None}
        merged['saved_person_coverage'] = ('mixed' if len(nonnil) > 1 else 'full' if nonnil and all(identities)
                                           else 'partial' if nonnil else 'none')
        merged['has_unattributed_words'] = any(supported_identity(r, speakers) is None for r in group)
        output.append(merged)
    return output


def passage_timing(row):
    """Project saved UTF-16 ranges through passage presentation without estimating time."""
    output, offset = [], 0
    for index, part in enumerate(row['constituents']):
        text = part['text']
        stripped = text.lstrip() if index == 0 else text
        removed = len(text.encode('utf-16-le')) // 2 - len(stripped.encode('utf-16-le')) // 2
        timing = part.get('timing')
        if isinstance(timing, dict) and timing.get('text') == text and isinstance(timing.get('spans'), list):
            encoded = text.encode('utf-16-le')
            position, last_start = 0, -math.inf
            spans = []
            for span in timing['spans']:
                if not isinstance(span, dict) or not isinstance(span.get('range'), dict):
                    spans = []
                    break
                location, length = span['range'].get('location'), span['range'].get('length')
                start, end = span.get('start'), span.get('end')
                if (type(location) is not int or type(length) is not int or location < position or length <= 0
                        or location + length > len(encoded) // 2
                        or type(start) not in (int, float) or type(end) not in (int, float)
                        or not math.isfinite(start) or not math.isfinite(end) or start < 0 or end <= start
                        or start < last_start or span.get('granularity') not in ('word', 'run')):
                    spans = []
                    break
                try:
                    token = encoded[location * 2:(location + length) * 2].decode('utf-16-le')
                except UnicodeDecodeError:
                    spans = []
                    break
                position, last_start = location + length, start
                # Presentation trims only whitespace from the first constituent.
                lower = max(location, removed)
                if lower < position and token.strip():
                    spans.append(dict(location=offset + lower - removed, length=position - lower,
                                      start=start, end=end, granularity=span['granularity']))
            output.extend(spans)
        offset += len(stripped.encode('utf-16-le')) // 2
    return output


def build_transcripts(source, root, samples):
    """Return flat rows, per-meeting source receipts, and aggregate coverage.

    ``sample_ids`` are overlapping eligible physical evidence, not whole-row identity
    assignments. A consumer must union coverage_intervals per consistent method result
    before applying any result to a whole row. Mixed results remain unresolved.
    """
    root = Path(root).resolve()
    library = root / 'library/meetings'
    by_meeting = defaultdict(list)
    audio_hashes = {}
    represented = ({s['id'] for s in source['samples'] if s.get('eligible', True)
                    and isinstance(s.get('embedding'), list) and 0 < len(s['embedding']) <= 4096
                    and all(isinstance(v, (float, int)) and math.isfinite(v) for v in s['embedding'])
                    and any(v != 0 for v in s['embedding'])}
                   if 'samples' in source else None)
    for sample in samples:
        sid = sample.get('sample_id') or sample.get('id')
        eligible = (sid in represented if represented is not None else sample.get('eligible', True)
                    and not sample.get('excluded') and not sample.get('manuallyCleared'))
        if eligible:
            by_meeting[sample.get('meeting_id') or sample.get('meetingID')].append(sample)
    output, meetings = [], []
    for meeting in sorted(source['meetings'], key=lambda m: m['meeting_order']):
        mid = meeting['id']
        receipt = {'meeting_id': mid, 'rows': 0, 'status': 'missing', 'warnings': [],
                   'transcript_source': None, 'speaker_label_source': None, 'canonical_rows': 0, 'audio_tracks': [], 'mix_available': False}
        meetings.append(receipt)
        try:
            folder = private_path(library, meeting['folder'])
            content = read_json(private_path(folder, 'content.json')) or {}
            receipt['transcript_source'] = content.get('transcriptSource')
            receipt['speaker_label_source'] = content.get('speakerLabelSource')
            rows, receipt['status'] = current_rows(folder)
            files = meeting.get('metadata', {}).get('audioFiles', content.get('audioFiles', []))
            speakers = {s['id']: s for s in content.get('speakers', meeting.get('speakers', []))}
            receipt['canonical_rows'] = len(rows)
            rows = passage_rows(rows, speakers)
            binding = []
            label_id = (content.get('speakerLabelSource') or {}).get('resultID')
            source_id = (content.get('transcriptSource') or {}).get('id')
            if label_id:
                artifact = read_json(private_path(folder, f'diarization-projection-{label_id}.json'))
                if artifact:
                    if artifact.get('version') == 1 and artifact.get('sourceID') == source_id and artifact.get('resultID') == label_id:
                        binding = artifact.get('audio') or []
                    else:
                        raise ValueError('The selected speaker-label audio binding does not match the selected transcript source.')
            if not binding and source_id:
                artifact = read_json(private_path(folder, f'transcription-source-{source_id}.json'))
                if artifact:
                    if artifact.get('version') == 1 and (artifact.get('source') or {}).get('id') == source_id:
                        binding = artifact.get('audio') or []
                    else:
                        raise ValueError('The selected transcript audio binding is invalid.')
            binding_by_track = {}
            for reference in binding:
                track = reference.get('trackID')
                offset = reference.get('recordingOffset', 0.)
                if (track in binding_by_track or track_index(track) is None or track_index(track) >= len(files)
                        or not isinstance(offset, (int, float)) or not math.isfinite(offset) or offset < 0
                        or not reference.get('revision')):
                    raise ValueError('The selected audio binding has invalid tracks, revisions, or recording offsets.')
                binding_by_track[track] = reference
            receipt['audio_tracks'] = [dict(index=i, audio_file=name, recording_key=f'{mid}/{i}',
                recording_offset=binding_by_track.get(f'track{i}', {}).get('recordingOffset', 0.),
                audio_available=private_path(folder, name).is_file(), available=private_path(folder, name).is_file())
                for i, name in enumerate(files)]
            receipt['mix_available'] = bool(files) and all(t['available'] for t in receipt['audio_tracks'])
            meeting_rows = []
            for row in rows:
                speaker = speakers.get(row.get('speakerID'), {})
                index = resolve_track(row, speaker, files)
                name = files[index] if index is not None else None
                audio = private_path(folder, name) if name else None
                reference = binding_by_track.get(f'track{index}', {}) if index is not None else {}
                offset = reference.get('recordingOffset', 0.)
                if not isinstance(offset, (int, float)) or not math.isfinite(offset) or offset < 0:
                    raise ValueError('The selected audio binding has an invalid recording offset.')
                start, end = row['start'], row['end']
                physical_start, physical_end = start - offset, end - offset
                overlaps = []
                if name:
                    for sample in by_meeting[mid]:
                        if sample_file(sample) != name:
                            continue
                        # A physical file and selected audio revision identify the source;
                        # imported files can have a UI source of system and acoustic source unknown.
                        revision = sample.get('audio_revision', sample.get('audioRevision'))
                        full_speech = sample.get('origin') == 'full-recording-speech-detection'
                        if full_speech:
                            # Fresh detection uses an exact byte hash, rather than the app's revision token.
                            if not audio or not audio.is_file():
                                continue
                            if audio not in audio_hashes:
                                with audio.open('rb') as handle:
                                    audio_hashes[audio] = hashlib.file_digest(handle, 'sha256').hexdigest()
                            if revision != audio_hashes[audio]:
                                continue
                        elif reference.get('revision') and revision != reference['revision']:
                            continue
                        resolved_source = reference.get('source') or file_source(name)
                        sample_source = sample.get('source')
                        if not full_speech and resolved_source != 'unknown' and sample_source != resolved_source:
                            continue
                        spans = sample.get('support_spans') or sample.get('spans') or []
                        sid = sample.get('sample_id') or sample.get('id')
                        for span in spans:
                            lower, upper = span.get('start'), span.get('end')
                            if (not isinstance(lower, (int, float)) or not isinstance(upper, (int, float))
                                    or not math.isfinite(lower) or not math.isfinite(upper) or not 0 <= lower < upper):
                                continue
                            lower, upper = max(lower, physical_start), min(upper, physical_end)
                            if lower < upper:
                                overlaps.append({'sample_id': sid, 'start': lower + offset, 'end': upper + offset})
                duration = end - start
                covered = union_length([(v['start'], v['end']) for v in overlaps])
                coverage = ('source_unresolved' if name is None else 'full' if duration > 0 and covered >= duration - 1e-7
                            else 'partial' if covered > 0 else 'none')
                uncertain = row.get('associationUncertain') is True or row.get('sourcePlaceholder') is True
                saved_identity = saved_person(row, speakers)
                meeting_rows.append({'id': f"{mid}:{row['id']}", 'row_id': row['id'], 'meeting_id': mid,
                    'start': start, 'end': end, 'text': row['text'], 'text_timing': passage_timing(row), 'source': row.get('source'),
                    'audio_file': name, 'recording_key': f'{mid}/{index}' if index is not None else None,
                    'track_index': index, 'audio_available': bool(audio and audio.is_file()),
                    'audio_start': physical_start, 'audio_end': physical_end, 'recording_offset': offset,
                    'local_label': row.get('speaker') or speaker.get('label'), 'speaker_id': row.get('speakerID'),
                    'saved_person_id': saved_identity,
                    'saved_person_tier': (speaker.get('voiceReviewOrigin') or {}).get('transcriptAssociationTier') if saved_identity else None,
                    'saved_person_coverage': row['saved_person_coverage'],
                    'has_unattributed_words': row['has_unattributed_words'],
                    'constituent_row_ids': row['constituent_row_ids'],
                    'constituents': [{key: part.get(key) for key in ('id', 'start', 'end', 'text', 'speakerID', 'personID',
                                      'associationUncertain', 'source', 'sourcePlaceholder')} for part in row['constituents']], 'saved_speaker_person_id': speaker.get('personID'),
                    'association_uncertain': uncertain, 'sample_ids': sorted({x['sample_id'] for x in overlaps}),
                    'coverage_intervals': overlaps, 'coverage': coverage, 'covered_seconds': covered,
                    'coverage_fraction': covered / duration if duration > 0 else 0.})
            output.extend(meeting_rows)
            receipt['rows'] = len(meeting_rows)
        except (OSError, ValueError, KeyError, TypeError) as error:
            receipt['status'] = 'failed'
            receipt['warnings'].append(str(error))
    counts = Counter(row['coverage'] for row in output)
    return {'rows': output, 'meetings': meetings, 'coverage': {
        'meetings': len(meetings), 'meetings_with_rows': sum(m['rows'] > 0 for m in meetings),
        'failed_meetings': sum(m['status'] == 'failed' for m in meetings), 'rows': len(output), 'canonical_rows': sum(m['canonical_rows'] for m in meetings),
        'audio_available_rows': sum(r['audio_available'] for r in output),
        'full_rows': counts['full'], 'partial_rows': counts['partial'], 'uncovered_rows': counts['none'],
        'source_unresolved_rows': counts['source_unresolved'],
        'transcript_seconds': sum(r['end'] - r['start'] for r in output),
        'covered_seconds': sum(r['covered_seconds'] for r in output)}}
