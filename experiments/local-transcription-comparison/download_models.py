#!/usr/bin/env python3
"""Download pinned public ASR artifacts into ignored local storage; no inference or uploads."""
from __future__ import annotations
import argparse
import os
from pathlib import Path
import subprocess
from compare import digest, private_output, write_json

NEMOTRON = 'FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML'
NEMOTRON_REVISION = '1a41b75758b0337ff67db7d5408280aaaf23074e'
WHISPER = 'argmaxinc/whisperkit-coreml'
WHISPER_REVISION = '0f63a7800b00dd0226abd051b906c246e1907482'
WHISPER_FOLDER = 'openai_whisper-large-v3-v20240930_626MB'
TOKENIZER = 'openai/whisper-large-v3-turbo'
TOKENIZER_REVISION = '41f01f3fe87f28c78e2fbf8b568835947dd65ed9'
TOKENIZER_FILES = ['tokenizer.json', 'tokenizer_config.json', 'added_tokens.json', 'special_tokens_map.json']


def download(root: Path) -> None:
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    environment = {**os.environ, 'HF_HUB_DISABLE_PROGRESS_BARS': '1',
                   'HF_HUB_CACHE': str(root/'.hub-cache'), 'HF_XET_CACHE': str(root/'.xet-cache')}
    requests = [(NEMOTRON, NEMOTRON_REVISION, root/'nemotron', [], ['latin/2240ms/**','multilingual/2240ms/**']),
                (WHISPER, WHISPER_REVISION, root/'whisper', [], [WHISPER_FOLDER+'/**']),
                (TOKENIZER, TOKENIZER_REVISION, root/'whisper'/WHISPER_FOLDER, TOKENIZER_FILES, [])]
    for repository, revision, destination, files, patterns in requests:
        command = ['hf','download',repository,*files,'--revision',revision,'--local-dir',str(destination),'--max-workers','4']
        for pattern in patterns:
            command.extend(['--include',pattern])
        subprocess.run(command, env=environment, check=True)
    models = []
    for name, repository, revision in [('nemotron',NEMOTRON,NEMOTRON_REVISION),('whisper',WHISPER,WHISPER_REVISION)]:
        files = [dict(path=str(path.relative_to(root/name)),bytes=path.stat().st_size,sha256=digest(path))
                 for path in sorted((root/name).rglob('*')) if path.is_file() and '.cache' not in path.parts]
        models.append(dict(id=name,repo=repository,revision=revision,files=files))
    models[1]['tokenizerSource'] = dict(repo=TOKENIZER,revision=TOKENIZER_REVISION,files=TOKENIZER_FILES)
    write_json(root/'manifest.json',dict(schemaVersion=1,models=models))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,required=True)
    args = parser.parse_args()
    download(private_output(args.root))
