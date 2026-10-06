"""Run the Jina/Granite/Qwen transcription ablation on fixed queries and audio."""

import argparse
import os
import subprocess
from pathlib import Path


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("dataset", type=Path)
    ap.add_argument("runs", type=Path)
    ap.add_argument("whisper", type=Path)
    ap.add_argument("patches", type=Path)
    ap.add_argument("output", type=Path)
    ap.add_argument(
        "--prepared",
        action="store_true",
        help="Use already prepared immutable variant datasets.",
    )
    a = ap.parse_args()
    root = Path(__file__).resolve().parents[1]
    if not a.prepared:
        prepare(a, root)
    encode(a, root)


def prepare(a, root):
    subprocess.run(
        [
            "uv",
            "run",
            "--no-project",
            "--with",
            "opencc==1.2.0",
            str(root / "expanded/variants.py"),
            str(a.dataset),
            str(a.whisper),
            str(a.patches),
            str(a.output),
        ],
        check=True,
    )


def encode(a, root):
    for condition in ["imported", "whisperx", "review-patched-apple"]:
        dataset = a.output / condition
        for model in ["jina-text-only", "granite-311m", "qwen3-600m"]:
            output = dataset / "runs" / model
            command = [
                "uv",
                "run",
                "--no-project",
                "--python",
                "3.12",
                "--with-requirements",
                str(root / "requirements.txt"),
                str(root / "encode_text.py"),
                model,
                str(dataset),
                str(output),
                "--device",
                "mps",
            ]
            print("Starting", condition, model, flush=True)
            with (dataset / (model + ".log")).open("w") as log:
                subprocess.run(
                    command,
                    env=dict(os.environ, HF_HUB_OFFLINE="1"),
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    check=True,
                )
            print("Completed", condition, model, flush=True)
    subprocess.run(
        [
            "uv",
            "run",
            "--no-project",
            "--with",
            "numpy",
            "--with",
            "scikit-learn",
            str(root / "expanded/score_variants.py"),
            str(a.dataset),
            str(a.runs),
            str(a.output),
            str(a.output / "comparison"),
        ],
        check=True,
    )


if __name__ == "__main__":
    main()
