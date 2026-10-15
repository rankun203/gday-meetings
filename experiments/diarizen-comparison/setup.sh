#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export UV_CACHE_DIR="${UV_CACHE_DIR:-/private/tmp/uv-cache}"
export UV_TOOL_DIR="${UV_TOOL_DIR:-/private/tmp/diarizen-uv-tools}"
export HF_HOME="$PWD/.local/hf"
mkdir -p .local
if [ ! -d .local/DiariZen/.git ]; then
  git clone https://github.com/BUTSpeechFIT/DiariZen.git .local/DiariZen
fi
git -C .local/DiariZen checkout 844f5555b0a98acd0931511fc641a8c5b8ba92c7
git -C .local/DiariZen apply --reverse --check ../../speechbrain-import.patch 2>/dev/null || git -C .local/DiariZen apply ../../speechbrain-import.patch
uv venv --python 3.10 .local/venv
uv pip install --python .local/venv/bin/python -r requirements-macos.lock
uv pip install --python .local/venv/bin/python --no-deps -e .local/DiariZen -e .local/DiariZen/pyannote-audio
uvx --from huggingface_hub hf download BUT-FIT/diarizen-wavlm-large-s80-md-v2 --revision 027b3e221b9d81dce2be794084f1dbd3ba2da403 --local-dir .local/model
uvx --from huggingface_hub hf download pyannote/wespeaker-voxceleb-resnet34-LM pytorch_model.bin --revision 837717ddb9ff5507820346191109dc79c958d614 --local-dir .local/embedding
