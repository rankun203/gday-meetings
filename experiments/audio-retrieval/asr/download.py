"""Download the fixed Whisper checkpoint used by the controlled ASR pilot."""

import argparse
import hashlib
import json
from pathlib import Path

from huggingface_hub import snapshot_download


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("output", type=Path)
    a = ap.parse_args()
    a.output.mkdir(parents=True, exist_ok=True)
    repo = "Systran/faster-whisper-large-v2"
    revision = "f0fe81560cb8b68660e564f55dd99207059c092e"
    path = Path(
        snapshot_download(
            repo,
            revision=revision,
            allow_patterns=["*.json", "*.bin", "*.txt"],
            cache_dir=str(a.output / "model-cache"),
        )
    ).resolve()
    (a.output / "whisper-model.json").write_text(
        json.dumps({"repo": repo, "revision": revision, "path": str(path)}, indent=2)
        + "\n"
    )
    (a.output / "whisper-model-files.json").write_text(
        json.dumps(
            {
                p.name: {
                    "bytes": p.stat().st_size,
                    "sha256": hashlib.sha256(p.read_bytes()).hexdigest(),
                }
                for p in path.iterdir()
                if p.is_file()
            },
            indent=2,
        )
        + "\n"
    )


if __name__ == "__main__":
    main()
