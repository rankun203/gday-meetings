#!/usr/bin/env python3
"""Build an offline listening page for final word labels, not acoustic turns."""
import argparse
import hashlib
import json
import os
from pathlib import Path
from urllib.parse import quote

from compare import interval, normalize_local, normalize_remote, write_private_text


def safe_json(value):
    return (json.dumps(value, ensure_ascii=False).replace('&', '\\u0026').replace('<', '\\u003c')
            .replace('>', '\\u003e').replace('\u2028', '\\u2028').replace('\u2029', '\\u2029'))


def exact_word_slices(segment):
    """Anchor provider tokens sequentially; never add spaces between character tokens."""
    words = segment.get('words') or []
    text = segment.get('text')
    if not isinstance(text, str):
        return [(word, word.get('word', ''), False) for word in words]
    cursor, pieces = 0, []
    for word in words:
        token = word.get('word', '').strip()
        found = text.find(token, cursor) if token else -1
        if found < 0 or any(c.isalnum() for c in text[cursor:found]):
            return [(item, item.get('word', ''), False) for item in words]
        end = found + len(token)
        pieces.append((word, text[cursor:end], True))
        cursor = end
    if pieces:
        if any(c.isalnum() for c in text[cursor:]):
            return [(item, item.get('word', ''), False) for item in words]
        word, value, exact = pieces[-1]
        pieces[-1] = (word, value + text[cursor:], exact)
    return pieces


def readable_tokens(tokens):
    """Reconstruct display spacing only; do not change tokens or timed attribution."""
    result, previous = '', ''
    for token in tokens:
        if not token:
            continue
        separator = ''
        if result and not result[-1].isspace() and not token[0].isspace():
            # CJK text and punctuation need no synthetic inter-token spaces.
            # Consecutive single ASCII letters are commonly character tokens.
            left, right = previous.strip(), token.strip()
            if (left and right and left[-1].isascii() and left[-1].isalnum()
                    and right[0].isascii() and right[0].isalnum()
                    and not (len(left) == len(right) == 1 and left.isalpha() and right.isalpha())):
                separator = ' '
        result += separator + token
        previous = token
    return result


def model(local, remote, state, comparison):
    # Reuse comparison's strict track validation; do not silently exchange sources.
    normalize_local(local, state['tracks'])
    normalize_remote(remote, state['tracks'])
    result = {'version': 2, 'methods': [{'id': 'local', 'name': 'This Mac + Community-1'},
                                        {'id': 'remote', 'name': 'RunPod worker'}], 'tracks': {}}
    source_tracks = {t['source']: t['track'] for t in state['tracks']}
    for track in state['tracks']:
        key = track['track']
        metrics = comparison['tracks'][key]
        if metrics['source'] != track['source'] or metrics['audio_sha256'] != track['sha256']:
            raise ValueError('Comparison metrics do not match the copied audio source.')
        left = []
        for row in local:
            if (row.get('analysisTrackID') or source_tracks.get(row.get('source'))) != key:
                continue
            if interval(row.get('start'), row.get('end'), None) is None:
                continue
            speaker_id = None if row.get('sourcePlaceholder') else row.get('speakerID')
            left.append({'start': row['start'], 'end': row['end'], 'text': row.get('text', ''),
                         'label': row.get('speaker') if speaker_id else None,
                         'mapped': metrics['local_to_remote_speaker_mapping'].get(speaker_id),
                         'uncertain': bool(row.get('associationUncertain')) if speaker_id else False,
                         'timed': row.get('timing', {}).get('text') == row.get('text') if row.get('timing') else False})
        right, untimed = [], []
        for segment_index, segment in enumerate(remote['output']['tracks'][key].get('segments', [])):
            words = segment.get('words') or []
            if not words:
                untimed.append(segment.get('text', ''))
            for word_index, (word, text, exact) in enumerate(exact_word_slices(segment)):
                item = interval(word.get('start'), word.get('end'), word.get('speaker'))
                if item is None:
                    untimed.append(text)
                    continue
                start, end, label = item
                # Preserve exact original spacing; no grouping across omitted words.
                if (right and right[-1]['label'] == label and right[-1]['end'] <= start
                        and start - right[-1]['end'] <= 1 and end - right[-1]['start'] <= 15
                        and right[-1]['segment'] == segment_index and right[-1]['lastWord'] == word_index - 1
                        and right[-1]['exactText'] == exact):
                    right[-1]['words'].append(word.get('word', ''))
                    right[-1]['text'] = (right[-1]['text'] + text if exact
                                         else readable_tokens(right[-1]['words']))
                    right[-1]['end'] = end
                    right[-1]['lastWord'] = word_index
                else:
                    right.append({'start': start, 'end': end, 'label': label, 'words': [word.get('word', '')],
                                  'text': text, 'exactText': exact, 'timed': True,
                                  'segment': segment_index, 'lastWord': word_index})
        anonymous = {label: 'Speaker ' + str(index + 1) for index, label in enumerate(sorted({
            row['label'] for row in right if row['label']}))}
        unmatched = {label: 'Unmatched speaker ' + str(index + 1) for index, label in enumerate(sorted({
            row['label'] for row in left if row['label'] and not row['mapped']}))}
        for row in left:
            row['displayLabel'] = anonymous.get(row['mapped']) or unmatched.get(row['label'])
        for row in right:
            row['displayLabel'] = anonymous.get(row['label'])
        candidates = [{'start': t, 'end': t + 30, 'reason': 'Opening recording', 'sampling': 'opening'}
                      for t in range(0, 120, 30)]
        duration = max([row['end'] for row in left + right], default=30)
        candidates += [{'start': round(max(0, duration - 30) * fraction, 3),
                        'end': round(max(0, duration - 30) * fraction, 3) + 30,
                        'reason': 'Uniformly spaced sample', 'sampling': 'uniform'}
                       for fraction in [0, .25, .5, .75, 1]]
        candidates += [dict(window, sampling='disagreement') for window in metrics.get('difference_windows', [])[:12]]
        result['tracks'][key] = {'source': track['source'], 'local': left, 'remote': right,
                                 'untimedRemoteText': untimed, 'windows': candidates, 'audioHash': track['sha256']}
    result['reviewId'] = hashlib.sha256(json.dumps(result, sort_keys=True, ensure_ascii=False).encode()).hexdigest()[:24]
    return result



def render(data):
    directory = Path(__file__).parent
    page = (directory / 'review.html').read_text()
    scripts = (directory / 'review_contract.js').read_text() + '\n' + (directory / 'review.js').read_text()
    return page.replace('>DATA</script>', '>' + safe_json(data) + '</script>').replace('/* REVIEW_SCRIPT */', scripts)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('local', 'remote', 'state', 'comparison', 'output'):
        parser.add_argument('--' + name, required=True, type=Path)
    args = parser.parse_args()
    state = json.loads(args.state.read_text())
    local = [json.loads(line) for line in args.local.read_text().splitlines() if line.strip()]
    data = model(local, json.loads(args.remote.read_text()), state, json.loads(args.comparison.read_text()))
    inputs = [args.local, args.remote, args.state, args.comparison]
    for track in state['tracks']:
        audio = (args.state.resolve().parent / track['file']).resolve()
        if not audio.is_relative_to(args.state.resolve().parent) or audio.suffix.lower() not in {'.opus', '.wav', '.m4a', '.mp3'}:
            raise ValueError('Use only prepared local audio inside the copied manifest directory.')
        with audio.open('rb') as file:
            digest = hashlib.file_digest(file, 'sha256').hexdigest()
        if digest != track['sha256']:
            raise ValueError('Prepared audio hash changed.')
        inputs.append(audio)
        data['tracks'][track['track']]['audio'] = quote(os.path.relpath(audio, args.output.resolve().parent), safe='/')
    write_private_text(args.output, render(data), inputs)


if __name__ == '__main__':
    main()
