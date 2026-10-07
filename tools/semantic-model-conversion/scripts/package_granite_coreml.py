"""Combine validated short-query and document encoders with shared Core ML weights."""
import argparse
import hashlib
import json
import shutil
import subprocess
from pathlib import Path

import coremltools as ct


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('query', type=Path)
    p.add_argument('passage', type=Path)
    p.add_argument('tokenizer', type=Path)
    p.add_argument('output', type=Path)
    a = p.parse_args()
    a.output.mkdir(parents=True, exist_ok=False)
    desc = ct.utils.MultiFunctionDescriptor()
    desc.add_function(str(a.query), 'main', 'query128')
    desc.add_function(str(a.passage), 'main', 'passage512')
    desc.default_function_name = 'query128'
    package = a.output / 'SemanticEncoder.mlpackage'
    ct.utils.save_multifunction(desc, str(package))
    subprocess.run(['xcrun', 'coremlcompiler', 'compile', str(package), str(a.output)], check=True)
    for name in ['tokenizer.json', 'tokenizer_config.json', 'special_tokens_map.json', 'LICENSE']:
        shutil.copy2(a.tokenizer / name, a.output / name)
    files = []
    for path in sorted(a.output.rglob('*')):
        if path.is_file():
            with path.open('rb') as f:
                digest = hashlib.file_digest(f, 'sha256').hexdigest()
            files.append({'path': str(path.relative_to(a.output)), 'bytes': path.stat().st_size, 'sha256': digest})
    manifest = {'format': 'coreml-multifunction', 'precision': 'mixed-fp16',
                'functions': {'query128': 128, 'passage512': 512}, 'defaultFunction': 'query128',
                'pooling': 'cls', 'normalization': 'l2', 'queryPrefix': '', 'passagePrefix': '', 'files': files}
    (a.output / 'semantic-model.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({'output': str(a.output), 'packageBytes': sum(x['bytes'] for x in files if x['path'].startswith('SemanticEncoder.mlpackage/'))}))


if __name__ == '__main__':
    main()
