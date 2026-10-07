"""Choose a threshold on one declared calibration sample, then freeze it."""

import argparse
import json
from pathlib import Path
import subprocess

from score import intervals, private_output, score, sha


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--sample", default="sample-B-coverage")
    parser.add_argument("--rollover", choices=["on", "off"], default="on")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--thresholds", type=float, nargs="+", default=[0.55, 0.60, 0.65, 0.70, 0.72, 0.75, 0.80, 0.85, 0.90])
    args = parser.parse_args()
    assert args.thresholds and all(0 < value < 1 for value in args.thresholds)
    assert len(set(args.thresholds)) == len(args.thresholds)
    root = args.manifest.resolve().parent
    manifest = json.loads(args.manifest.read_text())
    sample = next(s for s in manifest["samples"] if s["id"] == args.sample)
    assert sha(sample["referencesPath"]) == sample["referencesSHA256"]
    reference = json.loads(Path(sample["referencesPath"]).read_text())["silver"]
    evidence_path = root / (args.sample + "-" + args.rollover) / "evidence.json"
    receipt = json.loads((root / (args.sample + "-" + args.rollover + ".run.json")).read_text())
    assert receipt["returncode"] == 0 and receipt["inputSHA256"] == sample["audioSHA256"]
    assert sha(evidence_path) == receipt["artifacts"]["evidence.json"]
    evidence = json.loads(evidence_path.read_text())
    output = private_output(args.output)
    output.mkdir(parents=True, exist_ok=False)
    trials = []
    for threshold in args.thresholds:
        result_path = output / f"threshold-{threshold:.2f}.json"
        run = subprocess.run([str(args.runner.resolve()), str(evidence_path), str(result_path), str(threshold)],
                             check=True, capture_output=True, text=True)
        result = json.loads(result_path.read_text())
        _, candidate = intervals(evidence, result)
        measured = score(reference, candidate)
        trials.append(dict(threshold=threshold, metrics=measured, clusterCount=len(result["clusters"]),
                           outputSHA256=sha(result_path), runtime=run.stdout.strip()))
    best = min(trials, key=lambda t: (t["metrics"]["views"][0]["disagreement_fraction"], abs(t["threshold"]-0.72)))
    summary = dict(thresholdGrid=args.thresholds, calibrationSample=args.sample, rollover=args.rollover, reference="saved worker output; not ground truth",
                   evidenceSHA256=sha(evidence_path), runnerSHA256=sha(args.runner), trials=trials,
                   selectedThreshold=best["threshold"], selection="minimum full silver disagreement; ties nearest initial 0.72")
    (output / "calibration.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(dict(sample=args.sample, selectedThreshold=best["threshold"],
                         scores={str(t["threshold"]): t["metrics"]["views"][0]["disagreement_fraction"] for t in trials})))


if __name__ == "__main__":
    main()
