"""Score all systems against independently reviewed audio, including silence."""
import argparse
import hashlib
import json
from pathlib import Path

from compare_reference import compare
from private_paths import private_output


def score(gold, systems):
    if gold.get('status') != 'reviewed' or not gold.get('reviewedRegions'):
        raise ValueError('Independent review with explicit reviewed regions is required')
    if gold.get('selection') != 'independent':
        raise ValueError('Diagnostic clips cannot support an unbiased comparison')
    if not systems:
        raise ValueError('At least one system is required for comparison')
    duration = gold['audioDurationSeconds']
    intervals = gold['intervals']
    regions = gold['reviewedRegions']
    results = {}
    for name, hypothesis in systems.items():
        views = []
        for collar in (0, .25):
            for skip_overlap in (False, True):
                value = compare(intervals, hypothesis, duration, collar, skip_overlap, coverage=regions)
                value['reference_status'] = 'independently_reviewed_audio'
                value['diarization_error_rate'] = value.pop('disagreement_fraction')
                views.append(value)
        results[name] = views
    return {'schema_version': 1, 'systems': results,
            'interpretation': 'Lower error on these reviewed regions; not a population-wide superiority claim'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--gold', type=Path, required=True)
    parser.add_argument('--system', nargs=2, action='append', metavar=('NAME', 'INTERVALS_JSON'), required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = private_output(args.output)
    systems, hashes = {}, {}
    for name, source in args.system:
        if name in systems:
            parser.error('System names must be unique')
        path = Path(source)
        value = json.loads(path.read_text())
        systems[name] = value['intervals']
        hashes[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    result = score(json.loads(args.gold.read_text()), systems)
    result['gold_sha256'] = hashlib.sha256(args.gold.read_bytes()).hexdigest()
    result['system_sha256'] = hashes
    with output.open('x') as handle:
        handle.write(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
