"""Install the frozen capacity candidate into an isolated replay checkout."""

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE.parent / "diarization-benchmark"))
from private_paths import private_output


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package-path", type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    package = private_output(args.package_path)
    core = (package / "Sources/GdayMeetings/Core").resolve()
    if package not in core.parents:
        raise ValueError(
            "The copied source directory resolves outside the isolated package."
        )
    original = ROOT / "apps/client-macos-swift/Sources/GdayMeetings/Core"
    names = ("LiveSpeakerCapacity.swift", "SpeakerEvidence.swift")
    if any(
        (core / name).is_symlink() or package not in (core / name).resolve().parents
        for name in names
    ):
        raise ValueError(
            "Candidate destinations must be regular files inside the isolated package."
        )
    before = {name: (core / name).read_bytes() for name in names}
    if any(before[name] != (original / name).read_bytes() for name in names):
        raise ValueError(
            "The copied capacity sources differ from the production baseline."
        )
    candidate = (HERE / names[0]).read_bytes()
    revision = re.search(r'static let policyRevision = "([^"]+)"', candidate.decode())
    if revision is None:
        raise ValueError("The candidate has no explicit policy revision.")
    old = 'static let protectedPolicy = "nemotron-capacity-rollover-v1"'
    evidence = before[names[1]].decode()
    if evidence.count(old) != 1:
        raise ValueError("Unexpected baseline evidence policy declaration.")
    after = {
        names[0]: candidate,
        names[1]: evidence.replace(
            old, f'static let protectedPolicy = "{revision[1]}"'
        ).encode(),
    }
    receipt = package / "capacity-candidate-install.json"
    if receipt.exists():
        raise ValueError("This checkout already contains an experiment receipt.")
    for name, data in after.items():
        (core / name).write_bytes(data)
    with receipt.open("x") as handle:
        json.dump(
            {
                "policyRevision": revision[1],
                "beforeSHA256": {name: sha(data) for name, data in before.items()},
                "afterSHA256": {name: sha(data) for name, data in after.items()},
                "installerSHA256": sha(Path(__file__).read_bytes()),
            },
            handle,
            indent=2,
        )
        handle.write("\n")


if __name__ == "__main__":
    main()
