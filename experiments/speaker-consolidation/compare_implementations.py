"""Check optimized consolidation against a pinned implementation on synthetic data."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE.parent / "diarization-benchmark"))
from private_paths import private_output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline", default="1e4d09b")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{7,40}", args.baseline):
        parser.error("Baseline must be a commit hash")
    output = private_output(args.output)
    output.mkdir(parents=True, exist_ok=False)
    core = ROOT / "apps/client-macos-swift/Sources/GdayMeetings/Core"
    relative = str((core / "SpeakerConsolidation.swift").relative_to(ROOT))
    original = subprocess.check_output(["git", "show", args.baseline + ":" + relative], cwd=ROOT).decode()
    baseline = output / "SpeakerConsolidationBaseline.swift"
    baseline.write_text(re.sub(r"\bSpeakerConsolidation\b", "SpeakerConsolidationBaseline", original))
    sources = [core / name for name in (
        "LocalModels/TypedVoiceEmbedding.swift", "VoiceEmbeddingMath.swift", "SpeakerEvidence.swift",
        "VoiceProfileSelection.swift", "SpeakerConsolidation.swift",
        "SpeakerObservationClustering.swift", "SpeakerObservationConsolidation.swift")]
    sources += [baseline, HERE / "CompareImplementations.swift"]
    executable = output / "compare"
    command = ["xcrun", "swiftc", "-O", "-parse-as-library", *map(str, sources), "-o", str(executable)]
    subprocess.run(command, check=True)
    result = subprocess.run([str(executable)], capture_output=True, text=True)
    receipt = {
        "baseline": args.baseline,
        "sourceSHA256": {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources},
        "compiler": subprocess.check_output(["xcrun", "swiftc", "--version"], text=True).strip(),
        "command": command,
        "returncode": result.returncode,
        "stdout": result.stdout,
        "stderr": result.stderr,
    }
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(result.stdout, end="")
    if result.returncode:
        print(result.stderr, file=sys.stderr)
        raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
