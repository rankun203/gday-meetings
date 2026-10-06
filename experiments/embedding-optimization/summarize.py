"""Summarize timing receipts without including input text or embedding vectors."""
import argparse
import json
import statistics
from collections import defaultdict
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('directory', type=Path)
p.add_argument('output', type=Path)
a = p.parse_args()
groups = defaultdict(list)
for path in sorted(a.directory.glob('*.json')):
    name, repeat = path.stem.rsplit('-', 1)
    if repeat.isdigit():
        groups[name].append(json.loads(path.read_text()))
result = {}
for name, runs in groups.items():
    row = {'runs': len(runs), 'thermalStates': [r['thermalState'] for r in runs],
           'nonfiniteValues': sum(r['nonfiniteValues'] for r in runs),
           'minimumCosine': min(r['minimumCosine'] for r in runs)}
    for key in ['loadMs', 'firstPredictionMs', 'warmP50Ms', 'warmP95Ms']:
        values = [r[key] for r in runs]
        row[key] = {'median': statistics.median(values), 'minimum': min(values), 'maximum': max(values)}
    result[name] = row
a.output.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
