"""Compile exact production value algorithms with synthetic scale workloads."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
CORE = ROOT / "apps/client-macos-swift/Sources/GdayMeetings/Core"
sys.path.insert(0, str(HERE.parent / "diarization-benchmark"))
from private_paths import private_output


def sha(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mode", choices=["consolidation", "conflicts"], required=True)
    parser.add_argument("--consolidation-source", type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    output = private_output(args.output)
    output.mkdir(parents=True, exist_ok=False)
    type_source = CORE / "LocalModels/TypedVoiceEmbedding.swift"
    sources = [type_source]
    if args.mode == "consolidation":
        sources += [CORE / name for name in ("VoiceEmbeddingMath.swift", "SpeakerEvidence.swift", "VoiceProfileSelection.swift")]
        sources += [args.consolidation_source or CORE / "SpeakerConsolidation.swift", HERE / "ConsolidationBench.swift"]
    else:
        # Compile the actual independent production declarations, excluding app storage dependencies.
        store = CORE / "VoiceLibraryStore.swift"
        models = CORE / "VoiceLibrary.swift"
        text = store.read_text()
        if text.count("enum VoiceReviewConflicts {") != 1:
            raise ValueError("Unexpected conflict helper declaration")
        declaration = text[text.index("enum VoiceReviewConflicts {"):text.index("@MainActor")]
        model_text = models.read_text().split("/// A durable nil decision", 1)[0]
        if "struct VoiceExample:" not in model_text:
            raise ValueError("Unexpected voice metadata declarations")
        extracted = output / "ProductionConflictTypes.swift"
        extracted.write_text(model_text + "\n" + declaration)
        sources += [extracted, HERE / "ConflictBench.swift"]
    source_hashes = {str(path.resolve()): sha(path) for path in sources}
    if args.mode == "conflicts":
        source_hashes.update({str(path.resolve()): sha(path) for path in (store, models)})
    binary = output / "benchmark"
    command = ["xcrun", "swiftc", "-O", "-module-cache-path", str(output / "module-cache"),
               *[str(path) for path in sources], "-o", str(binary)]
    subprocess.run(command, check=True)
    completed = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
    if any(sha(Path(path)) != digest for path, digest in source_hashes.items()):
        raise ValueError("Benchmark sources changed during execution")
    (output / "timing.txt").write_text(completed.stdout)
    (output / "receipt.json").write_text(json.dumps(dict(mode=args.mode, command=command,
        sourceSHA256=source_hashes, binarySHA256=sha(binary), runnerSHA256=sha(__file__),
        swiftVersion=subprocess.check_output(["xcrun", "swiftc", "--version"], text=True).strip(),
        timingSHA256=sha(output / "timing.txt")), indent=2) + "\n")
    print(completed.stdout, end="")


if __name__ == "__main__":
    main()
