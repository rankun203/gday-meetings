"""Replay a frozen public capacity cohort through the production test bundle."""

import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

EXPERIMENTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(EXPERIMENTS / "diarization-benchmark"))
from private_paths import private_output


def sha(path):
    with Path(path).open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--models-data", type=Path, required=True)
    parser.add_argument("--package-path", type=Path, required=True)
    parser.add_argument("--test-bundle", type=Path, required=True)
    parser.add_argument(
        "--cohort", choices=["development", "validation"], required=True
    )
    parser.add_argument("--rollover", choices=["on", "off", "both"], default="both")
    parser.add_argument(
        "--configuration", choices=["debug", "release"], default="debug"
    )
    args = parser.parse_args()
    os.umask(0o077)
    source = json.loads(args.manifest.read_text())
    selected = [
        sample for sample in source["samples"] if sample["cohort"] == args.cohort
    ]
    if not selected:
        parser.error("The manifest contains no samples for this cohort.")
    for sample in selected:
        for field in ("audio", "ownership"):
            if sha(sample[field + "Path"]) != sample[field + "SHA256"]:
                raise ValueError(f"Changed {field} input for {sample['id']}")
    output = private_output(args.output)
    output.mkdir(parents=True, exist_ok=True)
    runtime_manifest = {
        "schemaVersion": 1,
        "samples": source["samples"],
        "dataDirectory": str(args.models_data.resolve()),
        "sourceManifestSHA256": sha(args.manifest),
        "selectionSHA256": source["selectionSHA256"],
    }
    manifest_path = output / "manifest.json"
    if manifest_path.exists():
        if json.loads(manifest_path.read_text()) != runtime_manifest:
            raise ValueError("Existing replay manifest does not match these inputs.")
    else:
        with manifest_path.open("x") as handle:
            json.dump(runtime_manifest, handle, indent=2)
            handle.write("\n")
    modes = ("off", "on") if args.rollover == "both" else (args.rollover,)
    for sample in selected:
        for mode in modes:
            attempt = output / (sample["id"] + "-" + mode)
            if attempt.exists() or attempt.with_suffix(".run.json").exists():
                raise ValueError("Use a fresh output directory for repeated attempts.")
            command = [
                sys.executable,
                "-B",
                str(EXPERIMENTS / "speaker-consolidation/run.py"),
                "--manifest",
                str(manifest_path),
                "--package-path",
                str(args.package_path),
                "--test-bundle",
                str(args.test_bundle),
                "--configuration",
                args.configuration,
                "--sample",
                sample["id"],
                "--rollover",
                mode,
            ]
            subprocess.run(command, check=True)


if __name__ == "__main__":
    main()
