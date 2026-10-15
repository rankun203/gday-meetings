#!/usr/bin/env python3
"""Render one immutable, offline speaker annotation batch."""
import argparse
import hashlib
import json
import os
import math
from pathlib import Path
import tempfile
from urllib.parse import quote

def write_private_text(destination, text, inputs):
    destination = destination.resolve()
    roots = [Path('/private/tmp'), Path(tempfile.gettempdir()).resolve(), Path(__file__).resolve().parent / '.local']
    if destination in {path.resolve() for path in inputs} or not any(destination.is_relative_to(root) for root in roots):
        raise ValueError('Choose a temporary output or this experiment’s ignored .local directory, distinct from inputs.')
    missing, parent = [], destination.parent
    while not parent.exists():
        missing.append(parent)
        parent = parent.parent
    for parent in reversed(missing):
        parent.mkdir(mode=0o700)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=destination.parent, delete=False) as stream:
            temporary = Path(stream.name)
            os.chmod(temporary, 0o600)
            stream.write(text)
        os.replace(temporary, destination)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def public_data(batch):
    """Omit sampling partitions, model predictions, and internal row identifiers."""
    tracks = {key: {k: value[k] for k in ('source', 'audio', 'sha256', 'duration')}
              for key, value in batch['tracks'].items()}
    items = []
    ids, item_ids = set(), set()
    def bounded(start, end, duration):
        return all(isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x) for x in (start, end, duration)) and 0 <= start < end <= duration
    for item in batch['items']:
        entry = {k: item[k] for k in ('id', 'track', 'start', 'end', 'contextText')}
        if entry['id'] in item_ids or entry['track'] not in tracks or not bounded(entry['start'], entry['end'], tracks[entry['track']]['duration']):
            raise ValueError('Invalid clip track or interval.')
        item_ids.add(entry['id'])
        entry['targets'] = []
        for target in item['targets']:
            if target['id'] in ids:
                raise ValueError('Target identifiers must be unique.')
            ids.add(target['id'])
            if not bounded(target['start'], target['end'], tracks[entry['track']]['duration']):
                raise ValueError('Invalid target interval.')
            if target['start'] < entry['start'] or target['end'] > entry['end']:
                raise ValueError('A target must remain inside its clip.')
            r = target.get('contextRange')
            if target['type'] == 'timedText' and (not r or not r.get('length')):
                raise ValueError('A timed text target needs a visible context range.')
            if r is not None:
                location, length = r['location'], r['length']
                if not all(isinstance(x, int) and not isinstance(x, bool) and x >= 0 for x in (location, length)):
                    raise ValueError('Invalid context text range.')
                encoded = entry['contextText'].encode('utf-16-le')
                if (location + length) * 2 > len(encoded) or encoded[location*2:(location+length)*2].decode('utf-16-le') != target['text']:
                    raise ValueError('Target text does not match its context range.')
            entry['targets'].append({k: target[k] for k in
                ('id', 'type', 'text', 'start', 'end', 'contextRange', 'granularity') if k in target})
        entry['references'] = [{k: reference[k] for k in ('id', 'label', 'start', 'end', 'relation')}
                               for reference in item.get('references', [])]
        reference_ids = set()
        for reference in entry['references']:
            if reference['id'] in reference_ids or not bounded(reference['start'], reference['end'], tracks[entry['track']]['duration']):
                raise ValueError('Invalid reference identifier or interval.')
            reference_ids.add(reference['id'])
        items.append(entry)
    return {'version': 1, 'reviewId': batch['reviewId'], 'inputHash': batch.get('inputHash', batch['reviewId']),
            'tracks': tracks, 'items': items}


def render(data):
    directory = Path(__file__).parent
    payload = json.dumps(data, ensure_ascii=False).replace('&', '\\u0026').replace('<', '\\u003c').replace('>', '\\u003e').replace('\u2028', '\\u2028').replace('\u2029', '\\u2029')
    return (directory / 'annotation.html').read_text().replace('>DATA</script>', '>' + payload + '</script>').replace('/* ANNOTATION_SCRIPT */', (directory / 'annotation.js').read_text())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    batch = json.loads(args.input.read_text())
    data = public_data(batch)
    inputs = [args.input]
    for track in data['tracks'].values():
        audio = Path(track['audio']).resolve()
        if audio.suffix.lower() not in {'.wav', '.opus', '.m4a', '.mp3'}:
            raise ValueError('Unsupported prepared audio format.')
        with audio.open('rb') as stream:
            if hashlib.file_digest(stream, 'sha256').hexdigest() != track['sha256']:
                raise ValueError('Prepared audio hash changed.')
        inputs.append(audio)
        track['audio'] = quote(os.path.relpath(audio, args.output.resolve().parent), safe='/')
    write_private_text(args.output, render(data), inputs)


if __name__ == '__main__':
    main()
