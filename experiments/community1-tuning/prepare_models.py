"""Verify an existing app cache against its catalog and stage read-only model links."""
import argparse
import hashlib
import json
import re
from pathlib import Path
from run import MODEL_REVISION, ROOT

p = argparse.ArgumentParser()
p.add_argument('directory', type=Path)
a = p.parse_args()
source = a.directory.resolve()
if source.name != MODEL_REVISION:
    p.error('Expected the pinned model revision directory.')
catalog = ROOT.parents[1]/'apps/client-macos-swift/Sources/GdayMeetings/Core/LocalModels/LocalModelRegistry.swift'
text = catalog.read_text().split('private static let communityAssets:', 1)[1].split('\n    ]', 1)[0]
assets = re.findall(r'path: "([^\"]+)",\s*remotePath: "[^\"]+",\s*bytes: ([\d_]+),\s*digest: "([0-9a-f]{40,64})"', text)
if len(assets) != 21: raise ValueError('Catalog structure changed; review before staging models.')
for path, size, digest in assets:
    data = (source/path).read_bytes()
    actual = (hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data) if len(digest) == 40 else hashlib.sha256(data)).hexdigest()
    if len(data) != int(size.replace('_', '')) or actual != digest:
        raise ValueError('Cached model verification failed: '+path)
output = ROOT/'.local/models'
output.mkdir(parents=True, exist_ok=False)
for name in sorted({Path(a[0]).parts[0] for a in assets}):
    (output/name).symlink_to(source/name, target_is_directory=(source/name).is_dir())
(output/'manifest.json').write_text(json.dumps({'revision': MODEL_REVISION,
    'catalogSHA256': hashlib.sha256(catalog.read_bytes()).hexdigest(), 'verifiedAssets': len(assets)}, indent=2))
print('Verified', len(assets), 'cached assets; staged local model links.')
