"""Replay the production reducer at recorded callback availability, without future window filtering."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "experiments/speaker-consolidation"))
from online_associate import availability_times  # noqa: E402
sys.path.insert(0, str(ROOT / "experiments/diarization-benchmark"))
from private_paths import private_output  # noqa: E402


def observations(evidence, trace):
    # This validates whole-file integrity, but computes admission using only the
    # continuity metadata encountered before each callback. It never consults
    # evidence.windows to decide whether an earlier sample can be admitted.
    admitted = availability_times(evidence, trace)
    samples = {s["id"]: s for s in evidence["samples"]}
    ready = {e["sampleID"]: (e["audioSubmittedThrough"], e["ordinal"]) for e in trace["entries"]
             if e["kind"] == "embeddingReady"}
    return [dict(sample=samples[sid], availableAt=clock, callbackOrdinal=ordinal,
                 embeddingReadyAt=ready[sid][0])
            for sid, (clock, ordinal, _) in sorted(admitted.items(), key=lambda item: (item[1][0], item[1][1], ready[item[0]][1]))]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--trace", required=True, type=Path)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    output = private_output(args.output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    inputs = {"evidence": args.evidence, "trace": args.trace, "binary": args.binary,
              "replayScript": Path(__file__),
              "admissionScript": ROOT / "experiments/speaker-consolidation/online_associate.py"}
    hashes = {k: hashlib.sha256(p.read_bytes()).hexdigest() for k, p in inputs.items()}
    evidence = json.loads(args.evidence.read_text())
    trace = json.loads(args.trace.read_text())
    rows = observations(evidence, trace)
    source = output / "observations.json"
    source.write_text(json.dumps(rows) + "\n")
    subprocess.run([str(args.binary.resolve()), str(source), str(output / "assignments.json")], check=True)
    if hashes != {k: hashlib.sha256(p.read_bytes()).hexdigest() for k, p in inputs.items()}:
        raise ValueError("Inputs changed during replay")
    result = json.loads((output / "assignments.json").read_text())
    summary = dict(inputSHA256=hashes, clock=trace["clock"], recordedEmbeddings=len(evidence["samples"]),
        admittedEmbeddings=len(rows), unresolvedAssignments=sum(a.get("clusterID") is None for a in result["assignments"]),
        clusters=result["clusterCount"], prefixInvariant=result["prefixInvariant"],
        checkedPrefixLengths=result["checkedPrefixLengths"],
        limitations=["Clock is submitted-audio upper bound, not measured inference latency",
                      "Original trace awaited extraction: sample coverage may exceed production async capture",
                      "Assignments concern sampled excerpts only; no complete live timeline or DER is claimed",
                      "Admission is based on prefix-observed window trust; no final-window lookahead"])
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
