"""Run the fixed expanded encoder shortlist sequentially, retaining per-run logs."""

import argparse
import os
import subprocess
import sys
from pathlib import Path


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("dataset", type=Path)
    ap.add_argument("output", type=Path)
    ap.add_argument("--clsp-cache", type=Path, required=True)
    ap.add_argument("--model-cache", type=Path, required=True)
    ap.add_argument("--e5-model", type=Path, required=True)
    a = ap.parse_args()
    root = Path(__file__).resolve().parents[1]
    a.output.mkdir(parents=True, exist_ok=True)
    common = [
        "uv",
        "run",
        "--no-project",
        "--python",
        "3.12",
        "--with-requirements",
        str(root / "requirements.txt"),
    ]
    env = dict(
        os.environ,
        HF_HOME=str(a.model_cache),
        HF_HUB_OFFLINE="1",
        TOKENIZERS_PARALLELISM="false",
    )
    jobs = []
    for name in [
        "jina-text-only",
        "granite-311m",
        "granite-97m",
        "harrier-270m",
        "harrier-600m",
        "qwen3-600m",
    ]:
        jobs.append(
            (
                name,
                common
                + [
                    str(root / "encode_text.py"),
                    name,
                    str(a.dataset),
                    str(a.output / name),
                    "--device",
                    "mps",
                ],
                env,
            )
        )
    for name in ["e5", "jina", "clap"]:
        command = common + [
            str(root / "encode.py"),
            name,
            str(a.dataset),
            str(a.output / name),
            "--device",
            "mps",
        ]
        if name == "e5":
            command += ["--local-model", str(a.e5_model)]
        jobs.append((name, command, env))
    clsp = ["uv", "run", "--no-project", "--python", "3.12"]
    for package in [
        "torch==2.8.0",
        "torchaudio==2.8.0",
        "transformers==4.57.3",
        "numpy",
        "soundfile",
        "einops",
        "timm",
    ]:
        clsp += ["--with", package]
    jobs.append(
        (
            "clsp",
            clsp
            + [
                str(root / "encode_clsp.py"),
                str(a.dataset),
                str(a.output / "clsp"),
                "--device",
                "mps",
            ],
            dict(env, HF_HOME=str(a.clsp_cache)),
        )
    )
    failures = []
    for name, command, variables in jobs:
        if (a.output / name / "complete.json").exists():
            print("Already complete", name, flush=True)
            continue
        print("Starting", name, flush=True)
        with (a.output / (name + ".log")).open("w") as log:
            result = subprocess.run(
                command,
                env=variables,
                stdout=log,
                stderr=subprocess.STDOUT,
                check=False,
            )
        print("Finished", name, result.returncode, flush=True)
        if result.returncode:
            failures.append(name)
    if failures:
        print("Failed runs:", ",".join(failures), flush=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
