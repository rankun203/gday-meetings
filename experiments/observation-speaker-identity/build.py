"""Compile the production observation candidate with explicit source receipts."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "experiments/diarization-benchmark"))
from private_paths import private_output  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--baseline", action="store_true")
    mode.add_argument("--causal", action="store_true")
    args = parser.parse_args()
    output = private_output(args.output).resolve()
    if output.exists():
        raise ValueError("Do not overwrite an evaluated binary")
    output.parent.mkdir(parents=True, exist_ok=True)
    core = ROOT / "apps/client-macos-swift/Sources/GdayMeetings/Core"
    sources = [core / name for name in ["LocalModels/TypedVoiceEmbedding.swift", "SpeakerEvidence.swift",
               "VoiceEmbeddingMath.swift", "VoiceProfileSelection.swift", "SpeakerConsolidation.swift",
               "SpeakerObservationClustering.swift", "SpeakerObservationConsolidation.swift"]]
    if args.causal:
        sources = [p for p in sources if p.name not in ("SpeakerConsolidation.swift", "SpeakerObservationConsolidation.swift")]
    sources += [Path(__file__).with_name("CausalReplay.swift" if args.causal else "Consolidate.swift")]
    hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(output.parent / "module-cache"), "-O",
                    *(["-D", "BASELINE"] if args.baseline else []), *(str(p) for p in sources), "-o", str(output)], check=True)
    if hashes != {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}:
        raise ValueError("Source changed during build")
    output.with_suffix(".build.json").write_text(json.dumps(dict(sources=hashes, baseline=args.baseline, causal=args.causal,
        binarySHA256=hashlib.sha256(output.read_bytes()).hexdigest()), indent=2) + "\n")


if __name__ == "__main__":
    main()
